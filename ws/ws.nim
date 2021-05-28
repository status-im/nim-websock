## Nim-Libp2p
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[tables,
            strutils,
            strformat,
            sequtils,
            uri,
            parseutils]

import pkg/[chronos,
            chronos/apps/http/httptable,
            chronos/streams/asyncstream,
            chronos/streams/tlsstream,
            chronicles,
            httputils,
            stew/byteutils,
            stew/endians2,
            stew/base64,
            stew/base10,
            nimcrypto/sha]

import ./utils, ./frame, ./session, /types, ./http

export utils, session, frame, types, http

type
  WSServer* = ref object of WebSocket
    protocols: seq[string]

func toException(e: string): ref WebSocketError =
  (ref WebSocketError)(msg: e)

func toException(e: cstring): ref WebSocketError =
  (ref WebSocketError)(msg: $e)

proc connect*(
  _: type WebSocket,
  uri: Uri,
  protocols: seq[string] = @[],
  flags: set[TLSFlags] = {},
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  rng: Rng = nil): Future[WSSession] {.async.} =
  ## create a new websockets client
  ##

  var rng = if isNil(rng): newRng() else: rng
  var key = Base64.encode(genWebSecKey(rng))
  var uri = uri
  let client = try:
    case uri.scheme:
    of "wss":
      uri.scheme = "https"
      await TlsHttpClient.connect(uri.hostname, uri.port.parseInt())
    of "ws":
      uri.scheme = "http"
      await HttpClient.connect(uri.hostname, uri.port.parseInt())
    else:
      raise newException(WSWrongUriSchemeError,
        "uri scheme has to be 'ws' or 'wss'")
  except CatchableError as exc:
    raise newException(
      TransportError, &"Cannot connect to ${uri}, Error: ${exc.msg}")

  let headerData = [
    ("Connection", "Upgrade"),
    ("Upgrade", "websocket"),
    ("Cache-Control", "no-cache"),
    ("Sec-WebSocket-Version", $version),
    ("Sec-WebSocket-Key", key)]

  var headers = HttpTable.init(headerData)
  if protocols.len != 0:
    headers.add("Sec-WebSocket-Protocol", protocols.join(", "))

  let response = try:
     await client.request(uri, headers = headers)
  except CatchableError as exc:
    debug "Websocket failed during handshake", exc = exc.msg
    await client.close()
    raise exc

  if response.code != Http101.toInt():
    raise newException(WSFailedUpgradeError,
          &"Server did not reply with a websocket upgrade: " &
          &"Header code: ${response.code} Header reason: ${response.reason} " &
          &"Address: ${client.address}")

  # Client data should be masked.
  return WSSession(
    stream: client.stream,
    readyState: ReadyState.Open,
    masked: true,
    rng: rng,
    frameSize: frameSize,
    onPing: onPing,
    onPong: onPong,
    onClose: onClose)

proc connect*(
  _: type WebSocket,
  host: string,
  port: Port,
  path: string,
  protocols: seq[string] = @[],
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil): Future[WSSession] {.async.} =
  ## Create a new websockets client
  ## using a string path
  ##

  var uri = "ws://" & host & ":" & $port
  if path.startsWith("/"):
    uri.add path
  else:
    uri.add "/" & path

  return await WebSocket.connect(
    parseUri(uri),
    protocols,
    {},
    version,
    frameSize,
    onPing,
    onPong,
    onClose)

proc tlsConnect*(
  _: type WebSocket,
  host: string,
  port: Port,
  path: string,
  protocols: seq[string] = @[],
  flags: set[TLSFlags] = {},
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  rng: Rng = nil): Future[WSSession] {.async.} =

  var uri = &"wss://${host}:${port}"
  if path.startsWith("/"):
    uri.add path
  else:
    uri.add &"/${path}"

  return await WebSocket.connect(
    parseUri(uri),
    protocols,
    flags,
    version,
    frameSize,
    onPing,
    onPong,
    onClose,
    rng)

proc handleRequest*(
  ws: WSServer,
  request: HttpRequest,
  version: uint = WSDefaultVersion): Future[WSSession]
  {.
    async,
    raises: [
      Defect,
      WSHandshakeError,
      WSProtoMismatchError]
  .} =
  ## Creates a new socket from a request.
  ##

  if not request.headers.contains("Sec-WebSocket-Version"):
    raise newException(WSHandshakeError, "Missing version header")

  ws.version = Base10.decode(
    uint,
    request.headers.getString("Sec-WebSocket-Version"))
    .tryGet() # this method throws

  if ws.version != version:
    raise newException(WSVersionError,
      "Websocket version not supported, Version: " &
      request.headers.getString("Sec-WebSocket-Version"))

  ws.key = request.headers.getString("Sec-WebSocket-Key").strip()
  var protos = @[""]
  if request.headers.contains("Sec-WebSocket-Protocol"):
    let wantProtos = request.headers.getList("Sec-WebSocket-Protocol")
    protos = wantProtos.filterIt(
      it in ws.protocols
    )

    let
      protosString = ws.protocols.join(", ")
      wantProtosString = wantProtos.join(", ")

    if protos.len <= 0:
      raise newException(WSProtoMismatchError,
        &"Protocol mismatch (expected: {protosString}" &
        &", got: {wantProtosString})")

  let
    cKey = ws.key & WSGuid
    acceptKey = Base64Pad.encode(
    sha1.digest(cKey.toOpenArray(0, cKey.high)).data)

  var headers = HttpTable.init([
    ("Connection", "Upgrade"),
    ("Upgrade", "websocket"),
    ("Sec-WebSocket-Accept", acceptKey)])
  if protos.len > 0:
    headers.add("Sec-WebSocket-Protocol", protos[0]) # send back the first matching proto

  try:
    await request.sendResponse(Http101, headers = headers)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    raise newException(WSHandshakeError,
        "Failed to sent handshake response. Error: " & exc.msg)

  return WSSession(
    readyState: ReadyState.Open,
    stream: request.stream,
    proto: protos[0],
    masked: false,
    rng: ws.rng,
    frameSize: ws.frameSize,
    onPing: ws.onPing,
    onPong: ws.onPong,
    onClose: ws.onClose)

proc new*(
  _: typedesc[WSServer],
  protos: openArray[string] = [""],
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  extensions: openArray[Extension] = [],
  rng: Rng = nil): WSServer =

  return WSServer(
    protocols: @protos,
    masked: false,
    rng: if isNil(rng): newRng() else: rng,
    frameSize: frameSize,
    onPing: onPing,
    onPong: onPong,
    onClose: onClose)
