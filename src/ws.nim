import std/[tables,
            strutils,
            uri,
            parseutils]

import pkg/[chronos,
            chronos/apps/http/httptable,
            chronos/apps/http/httpserver,
            chronos/streams/asyncstream,
            chronicles,
            httputils,
            stew/byteutils,
            stew/endians2,
            stew/base64,
            stew/base10,
            eth/keys,
            nimcrypto/sha]

import ./utils, ./stream

  #[
  +---------------------------------------------------------------+
  |0                   1                   2                   3  |
  |0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1|
  +-+-+-+-+-------+-+-------------+-------------------------------+
  |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
  |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
  |N|V|V|V|       |S|             |   (if payload len==126/127)   |
  | |1|2|3|       |K|             |                               |
  +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
  |     Extended payload length continued, if payload len == 127  |
  + - - - - - - - - - - - - - - - +-------------------------------+
  |                               |Masking-key, if MASK set to 1  |
  +-------------------------------+-------------------------------+
  | Masking-key (continued)       |          Payload Data         |
  +-------------------------------- - - - - - - - - - - - - - - - +
  :                     Payload Data continued ...                :
  + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
  |                     Payload Data continued ...                |
  +---------------------------------------------------------------+
  ]#

const
  SHA1DigestSize* = 20
  WSHeaderSize* = 12
  WSDefaultVersion* = 13
  WSDefaultFrameSize* = 1 shl 20 # 1mb
  WSMaxMessageSize* = 20 shl 20 # 20mb
  WSGuid* = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  CRLF* = "\r\n"

type
  ReadyState* {.pure.} = enum
    Connecting = 0 # The connection is not yet open.
    Open = 1       # The connection is open and ready to communicate.
    Closing = 2    # The connection is in the process of closing.
    Closed = 3     # The connection is closed or couldn't be opened.

  WebSocketError* = object of CatchableError
  WSMalformedHeaderError* = object of WebSocketError
  WSFailedUpgradeError* = object of WebSocketError
  WSVersionError* = object of WebSocketError
  WSProtoMismatchError* = object of WebSocketError
  WSMaskMismatchError* = object of WebSocketError
  WSHandshakeError* = object of WebSocketError
  WSOpcodeMismatchError* = object of WebSocketError
  WSRsvMismatchError* = object of WebSocketError
  WSWrongUriSchemeError* = object of WebSocketError
  WSMaxMessageSizeError* = object of WebSocketError
  WSClosedError* = object of WebSocketError
  WSSendError* = object of WebSocketError
  WSPayloadTooLarge* = object of WebSocketError
  WSOpcodeReserverdError* = object of WebSocketError
  WSFragmentedControlFrameError* = object of WebSocketError
  WSInvalidCloseCode* = object of WebSocketError
  WSPayloadLength* = object of WebSocketError
  WSInvalidOpcode* = object of WebSocketError

  Base16Error* = object of CatchableError
    ## Base16 specific exception type

  HeaderFlag* {.size: sizeof(uint8).} = enum
    rsv3
    rsv2
    rsv1
    fin
  HeaderFlags = set[HeaderFlag]

  HttpCode* = enum
    Http101 = 101 # Switching Protocols

  Opcode* {.pure.} = enum
    ## 4 bits. Defines the interpretation of the "Payload data".
    Cont = 0x0   ## Denotes a continuation frame.
    Text = 0x1   ## Denotes a text frame.
    Binary = 0x2 ## Denotes a binary frame.
    # 3-7 are reserved for further non-control frames.
    Close = 0x8  ## Denotes a connection close.
    Ping = 0x9   ## Denotes a ping.
    Pong = 0xa   ## Denotes a pong.
    # B-F are reserved for further control frames.

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
    # 3000-3999 reserved for libs
    # 4000-4999 reserved for applications

  Frame = ref object
    fin: bool                 ## Indicates that this is the final fragment in a message.
    rsv1: bool                ## MUST be 0 unless negotiated that defines meanings
    rsv2: bool                ## MUST be 0
    rsv3: bool                ## MUST be 0
    opcode: Opcode            ## Defines the interpretation of the "Payload data".
    mask: bool                ## Defines whether the "Payload data" is masked.
    data: seq[byte]           ## Payload data
    maskKey: array[4, char]   ## Masking key
    length: uint64            ## Message size.
    consumed: uint64          ## how much has been consumed from the frame

  ControlCb* = proc() {.gcsafe.}

  CloseResult* = tuple
    code: Status
    reason: string

  CloseCb* = proc(code: Status, reason: string):
    CloseResult {.gcsafe.}
 
  WebSocket* = ref object
    stream*: AsyncStream
    version*: uint
    key*: string
    protocol*: string
    readyState*: ReadyState
    masked*: bool # send masked packets
    rng*: ref BrHmacDrbgContext
    frameSize: int
    frame: Frame
    onPing: ControlCb
    onPong: ControlCb
    onClose: CloseCb

template remainder*(frame: Frame): uint64 =
  frame.length - frame.consumed

proc `$`(ht: HttpTables): string =
  ## Returns string representation of HttpTable/Ref.
  var res = ""
  for key,value in ht.stringItems(true):
      res.add(key.normalizeHeaderName())
      res.add(": ")
      res.add(value)
      res.add(CRLF)

  ## add for end of header mark
  res.add(CRLF)
  res

proc unmask*(
  data: var openArray[byte],
  maskKey: array[4, char],
  offset = 0) =
  ## Unmask a data payload using key
  ##

  for i in 0 ..< data.len:
    data[i] = (data[i].uint8 xor maskKey[(offset + i) mod 4].uint8)

proc prepareCloseBody(code: Status, reason: string): seq[byte] =
  result = reason.toBytes
  if ord(code) > 999:
    result = @(ord(code).uint16.toBytesBE()) & result

proc handshake*(
  ws: WebSocket,
  request: HttpRequestRef,
  version: uint = WSDefaultVersion) {.async.} =
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
  if reqHeaders.contains("Sec-WebSocket-Protocol"):
    let wantProtocol = reqHeaders.getString("Sec-WebSocket-Protocol").strip()
    if ws.protocol != wantProtocol:
      raise newException(WSProtoMismatchError,
        "Protocol mismatch (expected: " & ws.protocol & ", got: " &
        wantProtocol & ")")

  let cKey = ws.key & WSGuid
  let acceptKey = Base64Pad.encode(sha1.digest(cKey.toOpenArray(0, cKey.high)).data)

  var headerData = [("Connection", "Upgrade"),("Upgrade", "webSocket" ),
                      ("Sec-WebSocket-Accept", acceptKey)]
  var headers = HttpTable.init(headerData)
  if ws.protocol != "":
    headers.add("Sec-WebSocket-Protocol", ws.protocol)

  try:
    discard await request.respond(httputils.Http101, "", headers)
  except CatchableError as exc:
    raise newException(WSHandshakeError, "Failed to sent handshake response. Error: " & exc.msg)
  ws.readyState = ReadyState.Open

proc createServer*(
  request: HttpRequestRef,
  protocol: string = "",
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil): Future[WebSocket] {.async.} =
  ## Creates a new socket from a request.
  ##

  if not request.headers.contains("Sec-WebSocket-Version"):
    raise newException(WSHandshakeError, "Missing version header")

  let wsStream = AsyncStream(
    reader: request.connection.reader,
    writer: request.connection.writer)

  var ws = WebSocket(
    stream: wsStream,
    protocol: protocol,
    masked: false,
    rng: newRng(),
    frameSize: frameSize,
    onPing: onPing,
    onPong: onPong,
    onClose: onClose)

  await ws.handshake(request)
  return ws

proc encodeFrame*(f: Frame): seq[byte] =
  ## Encodes a frame into a string buffer.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  var ret: seq[byte]
  var b0 = (f.opcode.uint8 and 0x0f) # 0th byte: opcodes and flags.
  if f.fin:
    b0 = b0 or 128'u8

  ret.add(b0)

  # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
  # 1st byte: payload len start and mask bit.
  var b1 = 0'u8

  if f.data.len <= 125:
    b1 = f.data.len.uint8
  elif f.data.len > 125 and f.data.len <= 0xffff:
    b1 = 126'u8
  else:
    b1 = 127'u8

  if f.mask:
    b1 = b1 or (1 shl 7)

  ret.add(uint8 b1)

  # Only need more bytes if data len is 7+16 bits, or 7+64 bits.
  if f.data.len > 125 and f.data.len <= 0xffff:
    # Data len is 7+16 bits.
    var len = f.data.len.uint16
    ret.add ((len shr 8) and 255).uint8
    ret.add (len and 255).uint8
  elif f.data.len > 0xffff:
    # Data len is 7+64 bits.
    var len = f.data.len.uint64
    ret.add(len.toBytesBE())

  var data = f.data
  if f.mask:
    # If we need to mask it generate random mask key and mask the data.
    for i in 0..<data.len:
      data[i] = (data[i].uint8 xor f.maskKey[i mod 4].uint8)
    # Write mask key next.
    ret.add(f.maskKey[0].uint8)
    ret.add(f.maskKey[1].uint8)
    ret.add(f.maskKey[2].uint8)
    ret.add(f.maskKey[3].uint8)

  # Write the data.
  ret.add(data)
  return ret

proc send*(
  ws: WebSocket,
  data: seq[byte] = @[],
  opcode = Opcode.Text): Future[void] {.async.} =
  ## Send a frame
  ##

  if ws.readyState == ReadyState.Closed:
    raise newException(WSClosedError, "Socket is closed!")

  logScope:
    opcode = opcode
    dataSize = data.len

  debug "Sending data to remote"

  var maskKey: array[4, char]
  if ws.masked:
    maskKey = genMaskKey(ws.rng)

  if opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:
    if ws.readyState in {ReadyState.Closing} and opcode notin {Opcode.Close}:
      return
    await ws.stream.writer.write(encodeFrame(Frame(
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: opcode,
        mask: ws.masked,
        data: data, # allow sending data with close messages
        maskKey: maskKey)))
    return
  
  let maxSize = ws.frameSize
  var i = 0
  while ws.readyState notin {ReadyState.Closing}:
    let len = min(data.len, (maxSize + i))
    let encFrame = encodeFrame(Frame(
        fin: if (i + len >= data.len): true else: false,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: if i > 0: Opcode.Cont else: opcode, # fragments have to be `Continuation` frames
        mask: ws.masked,
        data: data[i ..< len],
        maskKey: maskKey))

    await ws.stream.writer.write(encFrame)
    i += len

    if i >= data.len :
      break

proc send*(ws: WebSocket, data: string): Future[void] =
  send(ws, toBytes(data), Opcode.Text)

proc handleClose*(ws: WebSocket, frame: Frame, payLoad: seq[byte] = @[]) {.async.} =

  if ws.readyState notin {ReadyState.Open}:
    return

  logScope:
    fin = frame.fin
    masked = frame.mask
    opcode = frame.opcode
    serverState = ws.readyState
  debug "Handling close sequence"

  var
    code = Status.Fulfilled 
    reason = ""

  if payLoad.len == 1:
    raise newException(WSPayloadLength,"Invalid close frame with payload length 1!")
  elif payLoad.len > 1:
    # first two bytes are the status
    let ccode = uint16.fromBytesBE(payLoad[0..<2])
    if ccode <= 999 or ccode > 1015:
      raise newException(WSInvalidCloseCode,"Invalid code in close message!")
    try:
      code = Status(ccode)
    except RangeError:
      code = Status.Fulfilled
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

proc handleControl*(ws: WebSocket, frame: Frame, payLoad: seq[byte] = @[]) {.async.} =
  ## handle control frames
  ##

  try:
    # Process control frame payload.
    case frame.opcode:
    of Opcode.Ping:
      if not isNil(ws.onPing):
        try:
          ws.onPing()
        except CatchableError as exc:
          debug "Exception in Ping callback, this is most likelly a bug", exc = exc.msg

      # send pong to remote
      await ws.send(payLoad, Opcode.Pong)
    of Opcode.Pong:
      if not isNil(ws.onPong):
        try:
          ws.onPong()
        except CatchableError as exc:
          debug "Exception in Pong callback, this is most likelly a bug", exc = exc.msg
    of Opcode.Close:
      await ws.handleClose(frame,payLoad)
    else:
      raise newException(WSInvalidOpcode, "Invalid control opcode")

  except WebSocketError as exc:
    debug "Handled websocket exception", exc = exc.msg
    raise exc
  except CatchableError as exc:
    trace "Exception handling control messages", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()
    
proc readFrame*(ws: WebSocket): Future[Frame] {.async.} =
  ## Gets a frame from the WebSocket.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2
  ##

  try:
    while ws.readyState != ReadyState.Closed: # read until a data frame arrives
      # Grab the header.
      var header = newSeq[byte](2)
      await ws.stream.reader.readExactly(addr header[0], 2)
      if header.len != 2:
        debug "Invalid websocket header length"
        raise newException(WSMalformedHeaderError, "Invalid websocket header length")

      let b0 = header[0].uint8
      let b1 = header[1].uint8

      var frame = Frame()
      # Read the flags and fin from the header.

      var hf = cast[HeaderFlags](b0 shr 4)
      frame.fin = fin in hf
      frame.rsv1 = rsv1 in hf
      frame.rsv2 = rsv2 in hf
      frame.rsv3 = rsv3 in hf

      let opcode = (b0 and 0x0f)
      if opcode > ord(Opcode.high):
        raise newException(WSOpcodeMismatchError, "Wrong opcode!")
      
      let frameOpcode = (opcode).Opcode
      if frameOpcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary, Opcode.Ping,Opcode.Pong,Opcode.Close}:
        raise newException(WSOpcodeReserverdError, "Unknown opcode is received")

      frame.opcode = frameOpcode

      # If any of the rsv are set close the socket.
      if frame.rsv1 or frame.rsv2 or frame.rsv3:
        raise newException(WSRsvMismatchError, "WebSocket rsv mismatch")

      # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
      var finalLen: uint64 = 0

      let headerLen = uint(b1 and 0x7f)
      if headerLen == 0x7e:
        # Length must be 7+16 bits.
        var length = newSeq[byte](2)
        await ws.stream.reader.readExactly(addr length[0], 2)
        finalLen = uint16.fromBytesBE(length)
      elif headerLen == 0x7f:
        # Length must be 7+64 bits.
        var length = newSeq[byte](8)
        await ws.stream.reader.readExactly(addr length[0], 8)
        finalLen = uint64.fromBytesBE(length)
      else:
        # Length must be 7 bits.
        finalLen = headerLen
      frame.length = finalLen
      # Do we need to apply mask?
      frame.mask = (b1 and 0x80) == 0x80
      if ws.masked == frame.mask:
        # Server sends unmasked but accepts only masked.
        # Client sends masked but accepts only unmasked.
        raise newException(WSMaskMismatchError, "Socket mask mismatch")

      var maskKey = newSeq[byte](4)
      if frame.mask:
        # Read the mask.
        await ws.stream.reader.readExactly(addr maskKey[0], 4)
        for i in 0..<maskKey.len:
          frame.maskKey[i] = cast[char](maskKey[i])

      # return the current frame if it's not one of the control frames
      if frame.opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:
        if not frame.fin:
          raise newException(WSFragmentedControlFrameError, "Websocket fragmentation controlled fin error")
        if frame.length > 125:
          raise newException(WSPayloadTooLarge,
            "Control message payload is greater than 125 bytes!")
        
        var payLoad = newSeq[byte](frame.length)
        # Read control frame payload.
        if frame.length > 0:
          # Read data
          await ws.stream.reader.readExactly(addr payLoad[0], frame.length.int)
          unmask(payLoad.toOpenArray(0, payLoad.high), frame.maskKey)
        # TODO: Fix this.
        asyncCheck ws.handleControl(frame,payLoad) # process control frames
        continue

      debug "Decoded new frame", opcode = frame.opcode, len = frame.length, mask = frame.mask

      return frame
  except WSOpcodeReserverdError as exc:
    trace "Handled websocket opcode exception",exc = exc.msg
    raise exc
  except WSPayloadTooLarge as exc:
    debug "Handled payload too large exception", exc = exc.msg
    raise exc
  except WebSocketError as exc:
    debug "Handled websocket exception", exc = exc.msg
    raise exc
  except CatchableError as exc:
    debug "Exception reading frame, dropping socket", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()
    raise exc

proc ping*(ws: WebSocket): Future[void] =
  ws.send(opcode = Opcode.Ping)

proc recv*(
  ws: WebSocket,
  data: pointer,
  size: int): Future[int] {.async.} =
  ## Attempts to read up to `size` bytes
  ##
  ## Will read as many frames as necesary
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
      # all has been consumed from the frame
      # read the next frame
      if isNil(ws.frame):
        ws.frame = await ws.readFrame()
        if ws.frame.opcode == Opcode.Cont:
          raise newException(WSOpcodeMismatchError, "first frame cannot be continue frame")
      elif (not ws.frame.fin and ws.frame.remainder() <= 0):
        ws.frame = await ws.readFrame()
        if ws.frame.opcode != Opcode.Cont:
          raise newException(WSOpcodeMismatchError, "expected continue frame")
      
      if ws.frame.fin and ws.frame.remainder().int <= 0:
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
        unmask(
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
  ws: WebSocket,
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
  ws: WebSocket,
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
  headers: HttpTable): Future[AsyncStream] {.async.} =
  ## Initiate handshake with server

  var transp: StreamTransport
  try:
    transp = await connect(address)
  except CatchableError as exc:
    raise newException(
      TransportError,
      "Cannot connect to " & $transp.remoteAddress() & " Error: " & exc.msg)

  let reader = newAsyncStreamReader(transp)
  let writer = newAsyncStreamWriter(transp)
  let requestHeader = "GET " & uri.path & " HTTP/1.1" & CRLF & $headers
  await writer.write(requestHeader)
  let res = await reader.readHeaders()
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

  return AsyncStream(
    reader: reader,
    writer: writer)

proc connect*(
  _: type WebSocket,
  uri: Uri,
  protocols: seq[string] = @[],
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil): Future[WebSocket] {.async.} =
  ## create a new websockets client
  ##

  var key = Base64.encode(genWebSecKey(newRng()))
  var uri = uri
  case uri.scheme
  of "ws":
    uri.scheme = "http"
  else:
    raise newException(WSWrongUriSchemeError, "uri scheme has to be 'ws'")

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
  let stream = await initiateHandshake(uri, address, headers)

  # Client data should be masked.
  return WebSocket(
    stream: stream,
    readyState: Open,
    masked: true,
    rng: newRng(),
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
  onClose: CloseCb = nil): Future[WebSocket] {.async.} =
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
    version,
    frameSize,
    onPing,
    onPong,
    onClose)
