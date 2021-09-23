## nim-websock
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
            uri]

import pkg/[chronos,
            chronos/apps/http/httptable,
            chronos/streams/asyncstream,
            chronos/streams/tlsstream,
            chronicles,
            httputils,
            stew/byteutils,
            stew/base64,
            stew/base10,
            nimcrypto/sha]

import ./utils, ./frame, ./session, /types, ./http, ./extensions/extutils

export utils, session, frame, types, http

logScope:
  topics = "websock ws-server"

type
  WSServer* = ref object of WebSocket
    protocols: seq[string]
    factories: seq[ExtFactory]

func toException(e: string): ref WebSocketError =
  (ref WebSocketError)(msg: e)

func toException(e: cstring): ref WebSocketError =
  (ref WebSocketError)(msg: $e)

func contains(extensions: openArray[Ext], extName: string): bool =
  for ext in extensions:
    if ext.name == extName:
      return true

proc getFactory(factories: openArray[ExtFactory], extName: string): ExtFactoryProc =
  for n in factories:
    if n.name == extName:
      return n.factory

proc selectExt(isServer: bool,
  extensions: var seq[Ext],
  factories: openArray[ExtFactory],
  exts: openArray[string]): string {.raises: [Defect, WSExtError].} =

  var extList: seq[AppExt]
  var response = ""
  for ext in exts:
    # each of "Sec-WebSocket-Extensions" can have multiple
    # extensions or fallback extension
    if not parseExt(ext, extList):
      raise newException(WSExtError, "extension syntax error: " & ext)

  for i, ext in extList:
    if extensions.contains(ext.name):
      # don't accept this fallback if prev ext
      # configuration already accepted
      trace "extension fallback not accepted", ext=ext.name
      continue

    # now look for right factory
    let factory = factories.getFactory(ext.name)
    if factory.isNil:
      # no factory? it's ok, just skip it
      trace "no extension factory", ext=ext.name
      continue

    let extRes = factory(isServer, ext.params)
    if extRes.isErr:
      # cannot create extension because of
      # wrong/incompatible params? skip or fallback
      trace "skip extension", ext=ext.name, msg=extRes.error
      continue

    let ext = extRes.get()
    doAssert(not ext.isNil)
    if i > 0:
      # add separator if more than one exts
      response.add ", "
    response.add ext.toHttpOptions

    # finally, accept the extension
    trace "extension accepted", ext=ext.name
    extensions.add ext

  # HTTP response for "Sec-WebSocket-Extensions"
  response

proc connect*(
  _: type WebSocket,
  host: string | TransportAddress,
  path: string,
  hostName: string = "", # override used when the hostname has been externally resolved
  protocols: seq[string] = @[],
  factories: seq[ExtFactory] = @[],
  secure = false,
  flags: set[TLSFlags] = {},
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  rng: Rng = nil): Future[WSSession] {.async.} =

  let
    rng = if isNil(rng): newRng() else: rng
    key = Base64Pad.encode(genWebSecKey(rng))
    hostname = if hostName.len > 0: hostName else: $host

  let client = if secure:
      await TlsHttpClient.connect(host, tlsFlags = flags, hostName = hostname)
    else:
      await HttpClient.connect(host)

  let headerData = [
    ("Connection", "Upgrade"),
    ("Upgrade", "websocket"),
    ("Cache-Control", "no-cache"),
    ("Sec-WebSocket-Version", $version),
    ("Sec-WebSocket-Key", key),
    ("Host", hostname)]

  var headers = HttpTable.init(headerData)
  if protocols.len > 0:
    headers.add("Sec-WebSocket-Protocol", protocols.join(", "))

  var extOffer = ""
  for i, f in factories:
    if i > 0:
      extOffer.add ", "
    extOffer.add f.clientOffer

  if extOffer.len > 0:
    headers.add("Sec-WebSocket-Extensions", extOffer)

  let response = try:
     await client.request(path, headers = headers)
  except CatchableError as exc:
    trace "Websocket failed during handshake", exc = exc.msg
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

  var extensions: seq[Ext]
  let exts = response.headers.getList("Sec-WebSocket-Extensions")
  discard selectExt(false, extensions, factories, exts)

  # Client data should be masked.
  let session = WSSession(
    stream: client.stream,
    readyState: ReadyState.Open,
    masked: true,
    extensions: system.move(extensions),
    rng: rng,
    frameSize: frameSize,
    onPing: onPing,
    onPong: onPong,
    onClose: onClose)

  for ext in session.extensions:
    ext.session = session

  return session

proc connect*(
  _: type WebSocket,
  uri: Uri,
  protocols: seq[string] = @[],
  factories: seq[ExtFactory] = @[],
  flags: set[TLSFlags] = {},
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  rng: Rng = nil): Future[WSSession]
  {.raises: [Defect, WSWrongUriSchemeError].} =
  ## Create a new websockets client
  ## using a Uri
  ##

  let secure = case uri.scheme:
    of "wss": true
    of "ws": false
    else:
      raise newException(WSWrongUriSchemeError,
        "uri scheme has to be 'ws' or 'wss'")

  var uri = uri
  if uri.port.len <= 0:
    uri.port = if secure: "443" else: "80"

  return WebSocket.connect(
    host = uri.hostname & ":" & uri.port,
    path = uri.path,
    protocols = protocols,
    factories = factories,
    secure = secure,
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
    trace "Websocket version not supported", version = ws.version

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
    trace "Didn't match any protocol", supported = ws.protocols, requested = wantProtos

  # it is possible to have multiple "Sec-WebSocket-Extensions"
  let exts = request.headers.getList("Sec-WebSocket-Extensions")
  let extResp = selectExt(true, ws.extensions, ws.factories, exts)
  if extResp.len > 0:
    # send back any accepted extensions
    headers.add("Sec-WebSocket-Extensions", extResp)

  try:
    await request.sendResponse(Http101, headers = headers)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    raise newException(WSHandshakeError,
        "Failed to sent handshake response. Error: " & exc.msg)

  let session = WSSession(
    readyState: ReadyState.Open,
    stream: request.stream,
    proto: protocol,
    extensions: system.move(ws.extensions),
    masked: false,
    rng: ws.rng,
    frameSize: ws.frameSize,
    onPing: ws.onPing,
    onPong: ws.onPong,
    onClose: ws.onClose)

  for ext in session.extensions:
    ext.session = session

  return session

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
