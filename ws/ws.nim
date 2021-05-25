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

import ./utils, ./stream, ./frame, ./errors, ./extension

const
  SHA1DigestSize* = 20
  WSHeaderSize* = 12
  WSDefaultVersion* = 13
  WSDefaultFrameSize* = 1 shl 20 # 1mb
  WSMaxMessageSize* = 20 shl 20  # 20mb
  WSGuid* = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  CRLF* = "\r\n"

type
  ReadyState* {.pure.} = enum
    Connecting = 0 # The connection is not yet open.
    Open = 1       # The connection is open and ready to communicate.
    Closing = 2    # The connection is in the process of closing.
    Closed = 3     # The connection is closed or couldn't be opened.

  HttpCode* = enum
    Http101 = 101 # Switching Protocols

  Status* {.pure.} = enum
    # 0-999 not used
    Fulfilled = 1000
    GoingAway = 1001
    ProtocolError = 1002
    CannotAccept = 1003
    # 1004 reserved
    NoStatus = 1005         # use by clients
    ClosedAbnormally = 1006 # use by clients
    Inconsistent = 1007
    PolicyError = 1008
    TooLarge = 1009
    NoExtensions = 1010
    UnexpectedError = 1011
    ReservedCode = 3999     # use by clients
                            # 3000-3999 reserved for libs
                            # 4000-4999 reserved for applications

  ControlCb* = proc(data: openArray[byte] = [])
    {.gcsafe, raises: [Defect].}

  CloseResult* = tuple
    code: Status
    reason: string

  CloseCb* = proc(code: Status, reason: string):
    CloseResult {.gcsafe, raises: [Defect].}

  WebSocket* = ref object of RootObj
    extensions: seq[Extension] # extension active for this session
    version*: uint
    key*: string
    proto*: string
    readyState*: ReadyState
    masked*: bool # send masked packets
    binary*: bool # is payload binary?
    rng*: ref BrHmacDrbgContext
    frameSize: int
    onPing: ControlCb
    onPong: ControlCb
    onClose: CloseCb

  WSServer* = ref object of WebSocket
    protocols: seq[string]

  WSSession* = ref object of WebSocket
    stream*: AsyncStream
    frame*: Frame

template remainder*(frame: Frame): uint64 =
  frame.length - frame.consumed

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

proc prepareCloseBody(code: Status, reason: string): seq[byte] =
  result = reason.toBytes
  if ord(code) > 999:
    result = @(ord(code).uint16.toBytesBE()) & result

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

proc send*(
  ws: WSSession,
  data: seq[byte] = @[],
  opcode: Opcode) {.async.} =
  ## Send a frame
  ##

  if ws.readyState == ReadyState.Closed:
    raise newException(WSClosedError, "Socket is closed!")

  logScope:
    opcode = opcode
    dataSize = data.len
    masked = ws.masked

  debug "Sending data to remote"

  var maskKey: array[4, char]
  if ws.masked:
    maskKey = genMaskKey(ws.rng)

  if opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:

    if ws.readyState in {ReadyState.Closing} and opcode notin {Opcode.Close}:
      return

    await ws.stream.writer.write(
      Frame(
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: opcode,
        mask: ws.masked,
        data: data, # allow sending data with close messages
        maskKey: maskKey)
        .encode())

    return

  let maxSize = ws.frameSize
  var i = 0
  while ws.readyState notin {ReadyState.Closing}:
    let len = min(data.len, (maxSize + i))
    await ws.stream.writer.write(
      Frame(
        fin: if (i + len >= data.len): true else: false,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: if i > 0: Opcode.Cont else: opcode, # fragments have to be `Continuation` frames
        mask: ws.masked,
        data: data[i ..< len],
        maskKey: maskKey)
        .encode())

    i += len
    if i >= data.len:
      break

proc send*(ws: WSSession, data: string): Future[void] =
  send(ws, toBytes(data), Opcode.Text)

proc handleClose*(ws: WSSession, frame: Frame, payLoad: seq[byte] = @[]) {.async.} =
  ## Handle close sequence
  ##

  logScope:
    fin = frame.fin
    masked = frame.mask
    opcode = frame.opcode
    readyState = ws.readyState

  debug "Handling close sequence"

  if ws.readyState notin {ReadyState.Open}:
    debug "Connection isn't open, abortig close sequence!"
    return

  var
    code = Status.Fulfilled
    reason = ""

  if payLoad.len == 1:
    raise newException(WSPayloadLengthError,
      "Invalid close frame with payload length 1!")

  if payLoad.len > 1:
    # first two bytes are the status
    let ccode = uint16.fromBytesBE(payLoad[0..<2])
    if ccode <= 999 or ccode > 1015:
      raise newException(WSInvalidCloseCodeError,
        "Invalid code in close message!")

    try:
      code = Status(ccode)
    except RangeError:
      raise newException(WSInvalidCloseCodeError,
        "Status code out of range!")

    # remining payload bytes are reason for closing
    reason = string.fromBytes(payLoad[2..payLoad.high])

  var rcode: Status
  if code in {Status.Fulfilled}:
    rcode = Status.Fulfilled

  if not isNil(ws.onClose):
    try:
      (rcode, reason) = ws.onClose(code, reason)
    except CatchableError as exc:
      debug "Exception in Close callback, this is most likely a bug", exc = exc.msg

  # don't respond to a terminated connection
  if ws.readyState != ReadyState.Closing:
    ws.readyState = ReadyState.Closing
    await ws.send(prepareCloseBody(rcode, reason), Opcode.Close)

    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()

proc handleControl*(ws: WSSession, frame: Frame) {.async.} =
  ## Handle control frames
  ##

  if not frame.fin:
    raise newException(WSFragmentedControlFrameError,
      "Control frame cannot be fragmented!")

  if frame.length > 125:
    raise newException(WSPayloadTooLarge,
      "Control message payload is greater than 125 bytes!")

  try:
    var payLoad = newSeq[byte](frame.length.int)
    if frame.length > 0:
      payLoad.setLen(frame.length.int)
      # Read control frame payload.
      await ws.stream.reader.readExactly(addr payLoad[0], frame.length.int)
      if frame.mask:
        mask(
          payLoad.toOpenArray(0, payLoad.high),
          frame.maskKey)

    # Process control frame payload.
    case frame.opcode:
    of Opcode.Ping:
      if not isNil(ws.onPing):
        try:
          ws.onPing(payLoad)
        except CatchableError as exc:
          debug "Exception in Ping callback, this is most likelly a bug", exc = exc.msg

      # send pong to remote
      await ws.send(payLoad, Opcode.Pong)
    of Opcode.Pong:
      if not isNil(ws.onPong):
        try:
          ws.onPong(payLoad)
        except CatchableError as exc:
          debug "Exception in Pong callback, this is most likelly a bug", exc = exc.msg
    of Opcode.Close:
      await ws.handleClose(frame, payLoad)
    else:
      raise newException(WSInvalidOpcodeError, "Invalid control opcode!")
  except WebSocketError as exc:
    debug "Handled websocket exception", exc = exc.msg
    raise exc
  except CatchableError as exc:
    trace "Exception handling control messages", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()

proc readFrame*(ws: WSSession): Future[Frame] {.async.} =
  ## Gets a frame from the WebSocket.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2
  ##

  try:
    while ws.readyState != ReadyState.Closed:
      let frame = await Frame.decode(ws.stream.reader, ws.masked)
      debug "Decoded new frame", opcode = frame.opcode, len = frame.length, mask = frame.mask

      # return the current frame if it's not one of the control frames
      if frame.opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:
        await ws.handleControl(frame) # process control frames# process control frames
        continue

      return frame
  except WebSocketError as exc:
    trace "Websocket error", exc = exc.msg
    raise exc
  except CatchableError as exc:
    debug "Exception reading frame, dropping socket", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()
    raise exc

proc ping*(ws: WSSession, data: seq[byte] = @[]): Future[void] =
  ws.send(data, opcode = Opcode.Ping)

proc recv*(
  ws: WSSession,
  data: pointer,
  size: int): Future[int] {.async.} =
  ## Attempts to read up to `size` bytes
  ##
  ## Will read as many frames as necessary
  ## to fill the buffer until either
  ## the message ends (frame.fin) or
  ## the buffer is full. If no data is on
  ## the pipe will await until at least
  ## one byte is available
  ##

  var consumed = 0
  var pbuffer = cast[ptr UncheckedArray[byte]](data)
  try:
    while consumed < size:
      # we might have to read more than
      # one frame to fill the buffer

      # TODO: Figure out a cleaner way to handle
      # retrieving new frames
      if isNil(ws.frame):
        ws.frame = await ws.readFrame()

        if isNil(ws.frame):
          return consumed

        if ws.frame.opcode == Opcode.Cont:
          raise newException(WSOpcodeMismatchError,
            "Expected Text or Binary frame")
      elif (not ws.frame.fin and ws.frame.remainder() <= 0):
        ws.frame = await ws.readFrame()
        # This could happen if the connection is closed.

        if isNil(ws.frame):
          return consumed

        if ws.frame.opcode != Opcode.Cont:
          raise newException(WSOpcodeMismatchError,
            "Expected Continuation frame")

      ws.binary = ws.frame.opcode == Opcode.Binary # set binary flag
      if ws.frame.fin and ws.frame.remainder() <= 0:
        ws.frame = nil
        break

      let len = min(ws.frame.remainder().int, size - consumed)
      if len == 0:
        continue

      let read = await ws.stream.reader.readOnce(addr pbuffer[consumed], len)
      if read <= 0:
        continue

      if ws.frame.mask:
        # unmask data using offset
        mask(
          pbuffer.toOpenArray(consumed, (consumed + read) - 1),
          ws.frame.maskKey,
          ws.frame.consumed.int)

      consumed += read
      ws.frame.consumed += read.uint64

    return consumed.int

  except WebSocketError as exc:
    debug "Websocket error", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()
    raise exc
  except CancelledError as exc:
    debug "Cancelling reading", exc = exc.msg
    raise exc
  except CatchableError as exc:
    debug "Exception reading frames", exc = exc.msg

proc recv*(
  ws: WSSession,
  size = WSMaxMessageSize): Future[seq[byte]] {.async.} =
  ## Attempt to read a full message up to max `size`
  ## bytes in `frameSize` chunks.
  ##
  ## If no `fin` flag arrives await until either
  ## cancelled or the `fin` flag arrives.
  ##
  ## If message is larger than `size` a `WSMaxMessageSizeError`
  ## exception is thrown.
  ##
  ## In all other cases it awaits a full message.
  ##
  var res: seq[byte]
  try:
    while ws.readyState != ReadyState.Closed:
      var buf = newSeq[byte](ws.frameSize)
      let read = await ws.recv(addr buf[0], buf.len)
      if read <= 0:
        break

      buf.setLen(read)
      if res.len + buf.len > size:
        raise newException(WSMaxMessageSizeError, "Max message size exceeded")

      res.add(buf)

      # no more frames
      if isNil(ws.frame):
        break

      # read the entire message, exit
      if ws.frame.fin and ws.frame.remainder().int <= 0:
        break
  except WebSocketError as exc:
    debug "Websocket error", exc = exc.msg
    raise exc
  except CancelledError as exc:
    debug "Cancelling reading", exc = exc.msg
    raise exc
  except CatchableError as exc:
    debug "Exception reading frames", exc = exc.msg

  return res

proc close*(
  ws: WSSession,
  code: Status = Status.Fulfilled,
  reason: string = "") {.async.} =
  ## Close the Socket, sends close packet.
  ##

  if ws.readyState != ReadyState.Open:
    return

  try:
    ws.readyState = ReadyState.Closing
    await ws.send(
      prepareCloseBody(code, reason),
      opcode = Opcode.Close)

    # read frames until closed
    while ws.readyState != ReadyState.Closed:
      discard await ws.recv()

  except CatchableError as exc:
    debug "Exception closing", exc = exc.msg

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
      "Cannot connect to " & $transp.remoteAddress() & " Error: " & exc.msg)

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
