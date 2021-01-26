import chronos, httputils, strutils, base64, std/sha1, random, http,
        uri, times, chronos/timer, tables, stew/byteutils, eth/[keys], stew/endians2

const
  SHA1DigestSize = 20
  WSHeaderSize = 12
  WSOpCode = {0x00, 0x01, 0x02, 0x08, 0x09, 0x0a}

type
  ReadyState* = enum
    Connecting = 0 # The connection is not yet open.
    Open = 1       # The connection is open and ready to communicate.
    Closing = 2    # The connection is in the process of closing.
    Closed = 3     # The connection is closed or couldn't be opened.

  WebSocket* = ref object
    tcpSocket*: StreamTransport
    version*: int
    key*: string
    protocol*: string
    readyState*: ReadyState
    masked*: bool # send masked packets
    rng*: ref BrHmacDrbgContext

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

proc handshake*(ws: WebSocket, header: HttpRequestHeader) {.async.} =
  ## Handles the websocket handshake.
  try: ws.version = parseInt(header["Sec-WebSocket-Version"])
  except ValueError:
    raise newException(WebSocketError, "Invalid Websocket version")

  if ws.version != 13:
    raise newException(WebSocketError, "Websocket version not supported, Version: " &
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
    acceptKey = base64.encode(hexToByteArray[SHA1DigestSize]($sh))
  except ValueError:
    raise newException(
      WebSocketError, "Failed to generate accept key: " & getCurrentExceptionMsg())

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

proc newWebSocket*(header: HttpRequestHeader, transp: StreamTransport,
                    protocol: string = ""): Future[WebSocket] {.async.} =
  ## Creates a new socket from a request.
  try:
    if not header.contains("Sec-WebSocket-Version"):
      raise newException(WebSocketError, "Invalid WebSocket handshake")
    var ws = WebSocket(tcpSocket: transp, protocol: protocol, masked: false,
        rng: newRng())
    await ws.handshake(header)
    return ws
  except ValueError, KeyError:
    # Wrap all exceptions in a WebSocketError so its easy to catch.
    raise newException(
      WebSocketError,
      "Failed to create WebSocket from request: " & getCurrentExceptionMsg()
    )

type
  Opcode* = enum
    ## 4 bits. Defines the interpretation of the "Payload data".
    Cont = 0x0   ## Denotes a continuation frame.
    Text = 0x1   ## Denotes a text frame.
    Binary = 0x2 ## Denotes a binary frame.
    # 3-7 are reserved for further non-control frames.
    Close = 0x8  ## Denotes a connection close.
    Ping = 0x9   ## Denotes a ping.
    Pong = 0xa   ## Denotes a pong.
    # B-F are reserved for further control frames.

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
  Frame = tuple
    fin: bool ## Indicates that this is the final fragment in a message.
    rsv1: bool ## MUST be 0 unless negotiated that defines meanings
    rsv2: bool ## MUST be 0
    rsv3: bool ## MUST be 0
    opcode: Opcode ## Defines the interpretation of the "Payload data".
    mask: bool ## Defines whether the "Payload data" is masked.
    data: seq[byte] ## Payload data
    maskKey: array[4, char] ## Masking key

proc encodeFrame(f: Frame): seq[byte] =
  ## Encodes a frame into a string buffer.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  var ret = newSeqOfCap[byte](f.data.len + WSHeaderSize)

  var b0 = (f.opcode.uint8 and 0x0f) # 0th byte: opcodes and flags.
  if f.fin:
    b0 = b0 or 128u8

  ret.add(b0)

  # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
  # 1st byte: payload len start and mask bit.
  var b1 = 0u8

  if f.data.len <= 125:
    b1 = f.data.len.uint8
  elif f.data.len > 125 and f.data.len <= 0xffff:
    b1 = 126u8
  else:
    b1 = 127u8

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
    ret.add ((len shr 56) and 255).uint8
    ret.add ((len shr 48) and 255).uint8
    ret.add ((len shr 40) and 255).uint8
    ret.add ((len shr 32) and 255).uint8
    ret.add ((len shr 24) and 255).uint8
    ret.add ((len shr 16) and 255).uint8
    ret.add ((len shr 8) and 255).uint8
    ret.add (len and 255).uint8

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

proc send*(ws: WebSocket, data: seq[byte], opcode = Opcode.Text): Future[
    void] {.async.} =
  try:
    var maskKey: array[4, char]
    if ws.masked:
      maskKey = genMaskKey(ws.rng)
    var frame = encodeFrame((
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: opcode,
      mask: ws.masked,
      data: data,
      maskKey: maskKey
    ))
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
  except IOError, OSError, ValueError:
    # Wrap all exceptions in a WebSocketError so its easy to catch
    raise newException(WebSocketError, "Failed to send data: " &
        getCurrentExceptionMsg())

proc sendStr*(ws: WebSocket, data: string, opcode = Opcode.Text): Future[
                void] {.async.} =
  await send(ws, toBytes(data), opcode)

proc close*(ws: WebSocket) =
  ## Close the Socket, sends close packet.
  ws.readyState = Closed
  proc close() {.async.} =
    await ws.send(@[], Close)
    ws.tcpSocket.close()
  asyncCheck close()

proc receiveFrame(ws: WebSocket): Future[Frame] {.async.} =
  ## Gets a frame from the WebSocket.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  # Grab the header.
  var header = newSeq[byte](2)
  try:
    await ws.tcpSocket.readExactly(addr header[0], 2)
  except TransportUseClosedError:
    ws.readyState = Closed
    raise newException(WebSocketError, "Socket closed")
  except CatchableError:
    ws.readyState = Closed
    raise newException(WebSocketError, "Failed to read websocket header")

  if header.len != 2:
    ws.readyState = Closed
    raise newException(WebSocketError, "Invalid websocket header length")

  let b0 = header[0].uint8
  let b1 = header[1].uint8

  var frame: Frame
  # Read the flags and fin from the header.

  var hf = cast[HeaderFlags](b0 shr 4)
  frame.fin = fin in hf
  frame.rsv1 = rsv1 in hf
  frame.rsv2 = rsv2 in hf
  frame.rsv3 = rsv3 in hf

  var opcode = b0 and 0x0f
  if opcode notin WSOpCode:
    raise newException(WebSocketError, "Unexpected  websocket opcode")
  frame.opcode = (opcode).Opcode

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

  # Read the data.
  var data = newSeq[byte](finalLen)
  await ws.tcpSocket.readExactly(addr data[0], int finalLen)
  frame.data = data
  if frame.data.len != int finalLen:
    raise newException(WebSocketError, "Failed to read websocket frame data")

  if frame.mask:
    # Apply mask, if we need too.
    for i in 0 ..< frame.data.len:
      frame.data[i] = (frame.data[i].uint8 xor maskKey[i mod 4].uint8)
  return frame

proc receivePacket*(ws: WebSocket): Future[(Opcode, seq[byte])] {.async.} =
  ## Wait for a string or binary packet to come in.
  var frame = await ws.receiveFrame()

  var packet = frame.data
  # If there are more parts read and wait for them
  while frame.fin != true:
    frame = await ws.receiveFrame()
    if frame.opcode != Cont:
      raise newException(WebSocketError, "Expected continuation frame")
    packet.add frame.data
  return (frame.opcode, packet)

proc receiveStrPacket*(ws: WebSocket): Future[seq[byte]] {.async.} =
  ## Wait only for only string and control packet to come. Errors out on Binary packets.
  let (opcode, data) = await ws.receivePacket()
  case opcode:
    of Text:
      return data
    of Binary:
      raise newException(WebSocketError, "Expected string packet, received binary packet")
    of Ping:
      await ws.send(data, Pong)
    of Pong:
      discard
    of Cont:
      discard
    of Close:
      ws.close()

proc validateWSClientHandshake*(transp: StreamTransport,
    header: HttpResponseHeader): void =
  if header.code != ord(Http101):
    raise newException(WebSocketError, "Server did not reply with a websocket upgrade: " &
          "Header code: " & $header.code &
          "Header reason: " & header.reason() &
          "Address: " & $transp.remoteAddress())

proc newWebsocketClient*(uri: Uri, protocols: seq[string] = @[]): Future[
    WebSocket] {.async.} =
  let
    keyDec = align(
      when declared(toUnix):
        $getTime().toUnix
      else:
        $getTime().toSeconds.int64, 16, '#')
    key = encode(keyDec)

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
    "Sec-WebSocket-Version": "13",
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
  return WebSocket(tcpSocket: client.transp, readyState: Open, masked: true,
      rng: newRng())

proc newWebsocketClient*(host: string, port: Port, path: string,
    protocols: seq[string] = @[]): Future[WebSocket] {.async.} =
  var uri = "ws://" & host & ":" & $port
  if path.startsWith("/"):
    uri.add path
  else:
    uri.add "/" & path
  return await newWebsocketClient(parseUri(uri), protocols)
