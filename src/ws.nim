import std/[tables,
            strutils,
            uri,
            sha1,
            parseutils]

import pkg/[chronos,
            httputils,
            stew/byteutils,
            stew/endians2,
            stew/base64,
            eth/keys]

import ./random, ./http

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
  SHA1DigestSize = 20
  WSHeaderSize = 12
  WSDefaultVersion = 13
  WSDefaultFrameSize* = 1024 * 1024 # 1kb

type
  ReadyState* = enum
    Connecting = 0 # The connection is not yet open.
    Open = 1       # The connection is open and ready to communicate.
    Closing = 2    # The connection is in the process of closing.
    Closed = 3     # The connection is closed or couldn't be opened.

  WebSocketError* = object of IOError

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

  WebSocket* = ref object
    tcpSocket*: StreamTransport
    version*: int
    key*: string
    protocol*: string
    readyState*: ReadyState
    masked*: bool # send masked packets
    rng*: ref BrHmacDrbgContext
    frame: Frame

func remainder(frame: Frame): uint64 =
  frame.length - frame.consumed

# Forward declare
proc close*(ws: WebSocket, initiator: bool = true) {.async.}

proc handshake*(
  ws: WebSocket,
  header: HttpRequestHeader,
  version = WSDefaultVersion) {.async.} =
  ## Handles the websocket handshake.
  ##

  discard parseSaturatedNatural(header["Sec-WebSocket-Version"], ws.version)
  if ws.version != version:
    raise newException(WebSocketError,
      "Websocket version not supported, Version: " &
      header["Sec-WebSocket-Version"])

  ws.key = header["Sec-WebSocket-Key"].strip()
  if header.contains("Sec-WebSocket-Protocol"):
    let wantProtocol = header["Sec-WebSocket-Protocol"].strip()
    if ws.protocol != wantProtocol:
      raise newException(WebSocketError,
        "Protocol mismatch (expected: " & ws.protocol & ", got: " &
        wantProtocol & ")")

  var acceptKey: string
  try:
    let sh = secureHash(ws.key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    acceptKey = Base64.encode(hexToByteArray[SHA1DigestSize]($sh))
  except ValueError:
    raise newException(
      WebSocketError,
      "Failed to generate accept key: " & getCurrentExceptionMsg())

  var response = "HTTP/1.1 101 Web Socket Protocol Handshake" & CRLF
  response.add("Sec-WebSocket-Accept: " & acceptKey & CRLF)
  response.add("Connection: Upgrade" & CRLF)
  response.add("Upgrade: webSocket" & CRLF)

  if ws.protocol != "":
    response.add("Sec-WebSocket-Protocol: " & ws.protocol & CRLF)
  response.add CRLF

  let res = await ws.tcpSocket.write(response)
  if res != len(response):
    raise newException(WebSocketError, "Failed to send handshake response to client")
  ws.readyState = Open

proc createServer*(
  header: HttpRequestHeader,
  transp: StreamTransport,
  protocol: string = ""): Future[WebSocket] {.async.} =
  ## Creates a new socket from a request.
  ##

  if not header.contains("Sec-WebSocket-Version"):
    raise newException(WebSocketError, "Invalid WebSocket handshake")

  try:
    var ws = WebSocket(
      tcpSocket: transp,
      protocol: protocol,
      masked: false,
      rng: newRng())
    await ws.handshake(header)
    return ws
  except ValueError, KeyError:
    # Wrap all exceptions in a WebSocketError so its easy to catch.
    raise newException(
      WebSocketError,
      "Failed to create WebSocket from request: " & getCurrentExceptionMsg()
    )

proc encodeFrame(f: Frame): seq[byte] =
  ## Encodes a frame into a string buffer.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  var ret = newSeqOfCap[byte](f.data.len + WSHeaderSize)

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
    var len = f.data.len
    ret.add(f.data.len.uint64.toBE().toBytesBE())

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
  data: seq[byte],
  opcode = Opcode.Text): Future[void] {.async.} =
  ## Send a frame
  ##

  try:
    var maskKey: array[4, char]
    if ws.masked:
      maskKey = genMaskKey(ws.rng)

    var inFrame = Frame(
       fin: true,
       rsv1: false,
       rsv2: false,
       rsv3: false,
       opcode: opcode,
       mask: ws.masked,
       data: data,
       maskKey: maskKey)

    var frame = encodeFrame(inFrame)
    const maxSize = 1024*1024
    # Send stuff in 1 megabyte chunks to prevent IOErrors.
    # This really large packets.
    var i = 0
    while i < frame.len:
      let frameSize = min(frame.len, i + maxSize)
      let res = await ws.tcpSocket.write(frame[i ..< frameSize])
      if res != frameSize:
        raise newException(ValueError, "Error while send websocket frame")
      i += maxSize
  except OSError, ValueError:
    # Wrap all exceptions in a WebSocketError so its easy to catch
    raise newException(WebSocketError, "Failed to send data: " &
        getCurrentExceptionMsg())

proc send*(ws: WebSocket, data: string): Future[void] =
  send(ws, toBytes(data), Opcode.Text)

proc handleControl(ws: WebSocket, frame: Frame) {.async.} =
  ## handle control frames
  ##
  var data = newSeq[byte](frame.length)

  # Read control frame payload.
  if frame.length > 0:
    # Read the data.
    await ws.tcpSocket.readExactly(addr data[0], int frame.length)
    frame.data = data

  # Process control frame payload.
  if frame.opcode == Ping:
    await ws.send(data, Pong)
  elif frame.opcode == Pong:
    discard
  elif frame.opcode == Close:
    await ws.close(false)

proc readFrame(ws: WebSocket): Future[Frame] {.async.} =
  ## Gets a frame from the WebSocket.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  while true: # read until a data frame arrives
    # Grab the header.
    var header = newSeq[byte](2)
    try:
      await ws.tcpSocket.readExactly(addr header[0], 2)
    except TransportUseClosedError:
      ws.readyState = Closed
      raise newException(WebSocketError, "Socket closed")

    if header.len != 2:
      ws.readyState = Closed
      raise newException(WebSocketError, "Invalid websocket header length")

    let b0 = header[0].uint8
    let b1 = header[1].uint8

    var frame = Frame()
    # Read the flags and fin from the header.

    var hf = cast[HeaderFlags](b0 shr 4)
    frame.fin = fin in hf
    frame.rsv1 = rsv1 in hf
    frame.rsv2 = rsv2 in hf
    frame.rsv3 = rsv3 in hf

    frame.opcode = (b0 and 0x0f).Opcode

    # If any of the rsv are set close the socket.
    if frame.rsv1 or frame.rsv2 or frame.rsv3:
      ws.readyState = Closed
      raise newException(WebSocketError, "WebSocket rsv mismatch")

    # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
    var finalLen: uint64 = 0

    let headerLen = uint(b1 and 0x7f)
    if headerLen == 0x7e:
      # Length must be 7+16 bits.
      var length = newSeq[byte](2)
      await ws.tcpSocket.readExactly(addr length[0], 2)
      finalLen = cast[ptr uint16](length[0].addr)[].toBE
    elif headerLen == 0x7f:
      # Length must be 7+64 bits.
      var length = newSeq[byte](8)
      await ws.tcpSocket.readExactly(addr length[0], 8)
      finalLen = cast[ptr uint64](length[0].addr)[].toBE
    else:
      # Length must be 7 bits.
      finalLen = headerLen
    frame.length = finalLen

    # Do we need to apply mask?
    frame.mask = (b1 and 0x80) == 0x80

    if ws.masked == frame.mask:
      # Server sends unmasked but accepts only masked.
      # Client sends masked but accepts only unmasked.
      raise newException(WebSocketError, "Socket mask mismatch")

    var maskKey = newSeq[byte](4)
    if frame.mask:
      # Read the mask.
      await ws.tcpSocket.readExactly(addr maskKey[0], 4)
      for i in 0..<maskKey.len:
        frame.maskKey[i] = cast[char](maskKey[i])

    # return the current frame if it's not one of the control frames
    if frame.opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:
      asyncSpawn ws.handleControl(frame) # process control frames
      continue

    return frame

proc close*(ws: WebSocket, initiator: bool = true) {.async.} =
  ## Close the Socket, sends close packet.
  if ws.readyState == Closed:
    discard ws.tcpSocket.closeWait()
    return
  ws.readyState = Closed
  await ws.send(@[], Close)
  if initiator == true:
    let frame = await ws.readFrame()
    if frame.opcode != Close:
      echo "Different packet type"
  await ws.close()

proc readMessage*(msgReader: MsgReader,data: seq[byte]): MsgReader {.async.} =
  while msgReader.readErr == nil:
    if msgReader.readRemaining > 0 :
      len = size(data)
      if len > msgReader.readRemaining:
        len = msgReader.readRemaining

      await msgReader.tcpSocket.readExactly(addr data, len)
      msgReader.readRemaining = msgReader.readRemaining - len
      msgReader.readLen = len

      if msgReader.mask:
        # Apply mask, if we need too.
        for i in 0 ..< len:
          data[i] = (data[i].uint8 xor msgReader.maskKey[i mod 4].uint8)

      if msgReader.readRemaining == 0:
        msgReader.readErr = EOFError

      return msgReader

    if msgReader.readFinal:
      msgReader.readLen = 0
      msgReader.readErr = EOFError
      return msgReader

    var frame = await ws.readFrame()
    if frame.fin:
      msgReader.readFinal = true
    msgReader.readRemaining = frame.length

    # Non-control frames cannot occur in the middle of a fragmented non-control frame.
    if frame.Opcode in Text || Binary:
      raise newException("websocket: internal error, unexpected text or binary in Reader")
  return msgReader

proc nextMessageReader*(ws: WebSocket): MsgReader =
  while true:
    # Handle control frames and return only on non control frames.
    var frame = await ws.readFrame()
    if frame.Opcode in Text || Binary:
      var msgReader: MsgReader
      msgReader.readFinal =  frame.fin
      msgReader.readRemaining = frame.readRemaining
      msgReader.tcpSocket = ws.tcpSocket
      msgReader.mask = frame.mask
      msgReader.maskKey = frame.maskKey
      return msgReader

proc close*(ws: WebSocket, initiator: bool = true) {.async.} =
  ## Close the Socket, sends close packet.
  if ws.readyState == Closed:
    discard ws.tcpSocket.closeWait()
    return
  ws.readyState = Closed
  await ws.send(@[], Close)
  if initiator == true:
    let frame = await ws.readFrame()
    if frame.opcode != Close:
      echo "Different packet type"
  await ws.close()

proc readMessage*(msgReader: MsgReader,data: seq[byte]): MsgReader {.async.} =
  while msgReader.readErr == nil:
    if msgReader.readRemaining > 0 :
      len = size(data)
      if len > msgReader.readRemaining:
        len = msgReader.readRemaining

      await msgReader.tcpSocket.readExactly(addr data, len)
      msgReader.readRemaining = msgReader.readRemaining - len
      msgReader.readLen = len

      if msgReader.mask:
        # Apply mask, if we need too.
        for i in 0 ..< len:
          data[i] = (data[i].uint8 xor msgReader.maskKey[i mod 4].uint8)

      if msgReader.readRemaining == 0:
        msgReader.readErr = EOFError

      return msgReader

    if msgReader.readFinal:
      msgReader.readLen = 0
      msgReader.readErr = EOFError
      return msgReader

    var frame = await ws.readFrame()
    if frame.fin:
      msgReader.readFinal = true
    msgReader.readRemaining = frame.length

    # Non-control frames cannot occur in the middle of a fragmented non-control frame.
    if frame.Opcode in Text || Binary:
      raise newException("websocket: internal error, unexpected text or binary in Reader")
  return msgReader

proc nextMessageReader*(ws: WebSocket): MsgReader =
  while true:
    # Handle control frames and return only on non control frames.
    var frame = await ws.readFrame()
    if frame.Opcode in Text || Binary:
      var msgReader: MsgReader
      msgReader.readFinal =  frame.fin
      msgReader.readRemaining = frame.readRemaining
      msgReader.tcpSocket = ws.tcpSocket
      msgReader.mask = frame.mask
      msgReader.maskKey = frame.maskKey
      return msgReader

proc receiveStrPacket*(ws: WebSocket): Future[seq[byte]] {.async.} =
  # TODO: remove this once PR is approved.
  return nil

  return read

proc validateWSClientHandshake(
  transp: StreamTransport,
  header: HttpResponseHeader): void =
  if header.code != ord(Http101):
    raise newException(WebSocketError,
          "Server did not reply with a websocket upgrade: " &
          "Header code: " & $header.code &
          "Header reason: " & header.reason() &
          "Address: " & $transp.remoteAddress())

proc connect*(
  uri: Uri,
  protocols: seq[string] = @[],
  version = WSDefaultVersion): Future[WebSocket] {.async.} =
  ## create a new websockets client
  ##

  var key = Base64.encode(genWebSecKey(newRng()))
  var uri = uri
  case uri.scheme
  of "ws":
    uri.scheme = "http"
  else:
    raise newException(WebSocketError, "uri scheme has to be 'ws'")

  var headers = newHttpHeaders({
    "Connection": "Upgrade",
    "Upgrade": "websocket",
    "Cache-Control": "no-cache",
    "Sec-WebSocket-Version": $version,
    "Sec-WebSocket-Key": key
  })

  if protocols.len != 0:
    headers.table["Sec-WebSocket-Protocol"] = @[protocols.join(", ")]

  let client = newHttpClient(headers)
  var response = await client.request($uri, "GET", headers = headers)
  var header = response.parseResponse()
  if header.failed():
    # Header could not be parsed
    raise newException(WebSocketError, "Malformed header received: " &
        $client.transp.remoteAddress())

  client.transp.validateWSClientHandshake(header)

  # Client data should be masked.
  return WebSocket(
    tcpSocket: client.transp,
    readyState: Open,
    masked: true,
    rng: newRng())

proc connect*(
  host: string,
  port: Port,
  path: string,
  protocols: seq[string] = @[]): Future[WebSocket] {.async.} =
  var uri = "ws://" & host & ":" & $port
  if path.startsWith("/"):
    uri.add path
  else:
    uri.add "/" & path

  return await connect(parseUri(uri), protocols)
