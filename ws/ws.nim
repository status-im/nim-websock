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

logScope:
  topics = "ws-server"

type
  WSServer* = ref object of WebSocket
    protocols: seq[string]
    factories: seq[ExtFactory]

func toException(e: string): ref WebSocketError =
  (ref WebSocketError)(msg: e)

func toException(e: cstring): ref WebSocketError =
  (ref WebSocketError)(msg: $e)

proc connect*(
  _: type WebSocket,
  uri: Uri,
  protocols: seq[string] = @[],
  extensions: seq[Ext] = @[],
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
  let client = case uri.scheme:
    of "wss":
      uri.scheme = "https"
      await TlsHttpClient.connect(uri.hostname, uri.port.parseInt(), tlsFlags = flags)
    of "ws":
      uri.scheme = "http"
      await HttpClient.connect(uri.hostname, uri.port.parseInt())
    else:
      raise newException(WSWrongUriSchemeError,
        "uri scheme has to be 'ws' or 'wss'")

  let headerData = [
    ("Connection", "Upgrade"),
    ("Upgrade", "websocket"),
    ("Cache-Control", "no-cache"),
    ("Sec-WebSocket-Version", $version),
    ("Sec-WebSocket-Key", key)]

  var headers = HttpTable.init(headerData)
  if protocols.len > 0:
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
          &"Header code: {response.code} Header reason: {response.reason} " &
          &"Address: {client.address}")

  let proto = response.headers.getString("Sec-WebSocket-Protocol")
  if proto.len > 0 and protocols.len > 0:
    if proto notin protocols:
      raise newException(WSFailedUpgradeError,
        &"Invalid protocol returned {proto}!")

  # Client data should be masked.
  return WSSession(
    stream: client.stream,
    readyState: ReadyState.Open,
    masked: true,
    extensions: @extensions,
    rng: rng,
    frameSize: frameSize,
    onPing: onPing,
    onPong: onPong,
    onClose: onClose)

proc connect*(
  _: type WebSocket,
  address: TransportAddress,
  path: string,
  protocols: seq[string] = @[],
  extensions: seq[Ext] = @[],
  secure = false,
  flags: set[TLSFlags] = {},
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  rng: Rng = nil): Future[WSSession] {.async.} =
  ## Create a new websockets client
  ## using a string path
  ##

  var uri = if secure:
      &"wss://"
    else:
      &"ws://"

  uri &= address.host & ":" & $address.port
  if path.startsWith("/"):
    uri.add path
  else:
    uri.add &"/{path}"

  return await WebSocket.connect(
    uri = parseUri(uri),
    protocols = protocols,
    extensions = extensions,
    flags = flags,
    version = version,
    frameSize = frameSize,
    onPing = onPing,
    onPong = onPong,
    onClose = onClose)

proc connect*(
  _: type WebSocket,
  host: string,
  port: Port,
  path: string,
  protocols: seq[string] = @[],
  extensions: seq[Ext] = @[],
  secure = false,
  flags: set[TLSFlags] = {},
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  rng: Rng = nil): Future[WSSession] {.async.} =

  return await WebSocket.connect(
    address = initTAddress(host, port),
    path = path,
    protocols = protocols,
    extensions = extensions,
    flags = flags,
    version = version,
    frameSize = frameSize,
    onPing = onPing,
    onPong = onPong,
    onClose = onClose,
    rng = rng)

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
    await request.stream.writer.sendError(Http426)
    debug "Websocket version not supported", version = ws.version

    raise newException(WSVersionError,
      &"Websocket version not supported, Version: {version}")

  ws.key = request.headers.getString("Sec-WebSocket-Key").strip()
  let wantProtos = if request.headers.contains("Sec-WebSocket-Protocol"):
        request.headers.getList("Sec-WebSocket-Protocol")
     else:
       @[""]

  let protos = wantProtos.filterIt(
    it in ws.protocols
  )

  let
    cKey = ws.key & WSGuid
    acceptKey = Base64Pad.encode(
      sha1.digest(cKey.toOpenArray(0, cKey.high)).data)

  var headers = HttpTable.init([
    ("Connection", "Upgrade"),
    ("Upgrade", "websocket"),
    ("Sec-WebSocket-Accept", acceptKey)])

  let protocol = if protos.len > 0: protos[0] else: ""
  if protocol.len > 0:
    headers.add("Sec-WebSocket-Protocol", protocol) # send back the first matching proto
  else:
    debug "Didn't match any protocol", supported = ws.protocols, requested = wantProtos

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
    proto: protocol,
    masked: false,
    rng: ws.rng,
    frameSize: ws.frameSize,
    onPing: ws.onPing,
    onPong: ws.onPong,
    onClose: ws.onClose)

proc new*(
  _: typedesc[WSServer],
  protos: openArray[string] = [""],
  factories: openArray[ExtFactory] = [],
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  rng: Rng = nil): WSServer =

  return WSServer(
    protocols: @protos,
    masked: false,
    rng: if isNil(rng): newRng() else: rng,
    frameSize: frameSize,
    factories: @factories,
    onPing: onPing,
    onPong: onPong,
    onClose: onClose)
