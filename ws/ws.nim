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
            sequtils,
            uri,
            parseutils]

import pkg/[chronos,
            chronos/apps/http/httptable,
            chronos/apps/http/httpserver,
            chronos/streams/asyncstream,
            chronos/streams/tlsstream,
            chronicles,
            httputils,
            stew/byteutils,
            stew/endians2,
            stew/base64,
            stew/base10,
            nimcrypto/sha]

import ./utils, ./stream, ./frame, ./session, /types

export utils, session, frame, stream, types

type
  HttpCode* = enum
    Http101 = 101 # Switching Protocols

  WSServer* = ref object of WebSocket
    protocols: seq[string]

proc `$`(ht: HttpTables): string =
  ## Returns string representation of HttpTable/Ref.
  var res = ""
  for key, value in ht.stringItems(true):
    res.add(key.normalizeHeaderName())
    res.add(": ")
    res.add(value)
    res.add(CRLF)

  ## add for end of header mark
  res.add(CRLF)
  res

proc handshake*(
  ws: WSServer,
  request: HttpRequestRef,
  stream: AsyncStream,
  version: uint = WSDefaultVersion): Future[WSSession] {.async.} =
  ## Handles the websocket handshake.
  ##

  let
    reqHeaders = request.headers

  ws.version = Base10.decode(
    uint,
    reqHeaders.getString("Sec-WebSocket-Version"))
    .tryGet() # this method throws

  if ws.version != version:
    raise newException(WSVersionError,
      "Websocket version not supported, Version: " &
      reqHeaders.getString("Sec-WebSocket-Version"))

  ws.key = reqHeaders.getString("Sec-WebSocket-Key").strip()
  var protos = @[""]
  if reqHeaders.contains("Sec-WebSocket-Protocol"):
    let wantProtos = reqHeaders.getList("Sec-WebSocket-Protocol")
    protos = wantProtos.filterIt(
      it in ws.protocols
    )

    if protos.len <= 0:
      raise newException(WSProtoMismatchError,
        "Protocol mismatch (expected: " & ws.protocols.join(", ") & ", got: " &
        wantProtos.join(", ") & ")")

  let
    cKey = ws.key & WSGuid
    acceptKey = Base64Pad.encode(
    sha1.digest(cKey.toOpenArray(0, cKey.high)).data)

  var headerData = [
    ("Connection", "Upgrade"),
    ("Upgrade", "webSocket"),
    ("Sec-WebSocket-Accept", acceptKey)]

  var headers = HttpTable.init(headerData)
  if protos.len > 0:
    headers.add("Sec-WebSocket-Protocol", protos[0]) # send back the first matching proto

  try:
    discard await request.respond(httputils.Http101, "", headers)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    raise newException(WSHandshakeError,
        "Failed to sent handshake response. Error: " & exc.msg)

  return WSSession(
    readyState: ReadyState.Open,
    stream: stream,
    proto: protos[0],
    masked: false,
    rng: ws.rng,
    frameSize: ws.frameSize,
    onPing: ws.onPing,
    onPong: ws.onPong,
    onClose: ws.onClose)

proc initiateHandshake(
  uri: Uri,
  address: TransportAddress,
  headers: HttpTable,
  flags: set[TLSFlags] = {}): Future[AsyncStream] {.async.} =
  ## Initiate handshake with server

  var transp: StreamTransport
  try:
    transp = await connect(address)
  except CatchableError as exc:
    raise newException(
      TransportError,
      "Cannot connect to " & $address & " Error: " & exc.msg)

  let
    requestHeader = "GET " & uri.path & " HTTP/1.1" & CRLF & $headers
    reader = newAsyncStreamReader(transp)
    writer = newAsyncStreamWriter(transp)

  var stream: AsyncStream

  try:
    var res: seq[byte]
    if uri.scheme == "https":
      let tlsstream = newTLSClientAsyncStream(reader, writer, "", flags = flags)
      stream = AsyncStream(
        reader: tlsstream.reader,
        writer: tlsstream.writer)

      await tlsstream.writer.write(requestHeader)
      res = await tlsstream.reader.readHeaders()
    else:
      stream = AsyncStream(
        reader: reader,
        writer: writer)
      await stream.writer.write(requestHeader)
      res = await stream.reader.readHeaders()

    if res.len == 0:
      raise newException(ValueError, "Empty response from server")

    let resHeader = res.parseResponse()
    if resHeader.failed():
      # Header could not be parsed
      raise newException(WSMalformedHeaderError, "Malformed header received.")

    if resHeader.code != ord(Http101):
      raise newException(WSFailedUpgradeError,
            "Server did not reply with a websocket upgrade:" &
            " Header code: " & $resHeader.code &
            " Header reason: " & resHeader.reason() &
            " Address: " & $transp.remoteAddress())
  except CatchableError as exc:
    debug "Websocket failed during handshake", exc = exc.msg
    await stream.closeWait()
    raise exc

  return stream

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

  var key = Base64.encode(genWebSecKey(newRng()))
  var uri = uri
  case uri.scheme
  of "ws":
    uri.scheme = "http"
  of "wss":
    uri.scheme = "https"
  else:
    raise newException(WSWrongUriSchemeError,
      "uri scheme has to be 'ws' or 'wss'")

  var headerData = [
    ("Connection", "Upgrade"),
    ("Upgrade", "websocket"),
    ("Cache-Control", "no-cache"),
    ("Sec-WebSocket-Version", $version),
    ("Sec-WebSocket-Key", key)]

  var headers = HttpTable.init(headerData)

  if protocols.len != 0:
    headers.add("Sec-WebSocket-Protocol", protocols.join(", "))

  let address = initTAddress(uri.hostname & ":" & uri.port)
  let stream = await initiateHandshake(uri, address, headers, flags)

  # Client data should be masked.
  return WSSession(
    stream: stream,
    readyState: ReadyState.Open,
    masked: true,
    rng: if isNil(rng): newRng() else: rng,
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

  var uri = "wss://" & host & ":" & $port
  if path.startsWith("/"):
    uri.add path
  else:
    uri.add "/" & path

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
  request: HttpRequestRef): Future[WSSession]
  {.raises: [Defect, WSHandshakeError].} =
  ## Creates a new socket from a request.
  ##

  if not request.headers.contains("Sec-WebSocket-Version"):
    raise newException(WSHandshakeError, "Missing version header")

  let wsStream = AsyncStream(
    reader: request.connection.reader,
    writer: request.connection.writer)

  return ws.handshake(request, wsStream)

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
