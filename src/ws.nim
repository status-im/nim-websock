import chronos, chronicles, httputils, strutils, base64, std/sha1, random,
    streams, nativesockets, uri, times, chronos/timer, tables, stew/bitops2, stew/byteutils

const
  MaxHttpHeadersSize = 8192       # maximum size of HTTP headers in octets
  MaxHttpRequestSize = 128 * 1024 # maximum size of HTTP body in octets
  HttpHeadersTimeout = timer.seconds(120) # timeout for receiving headers (120 sec)
  WebsocketUserAgent* = "nim-ws (https://github.com/status-im/nim-ws)"
  CRLF* = "\c\L"
  HeaderSep = @[byte('\c'), byte('\L'), byte('\c'), byte('\L')]
  SHA1DigestSize = 20

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

  AsyncCallback = proc (transp: StreamTransport,
      header: HttpRequestHeader): Future[void] {.closure, gcsafe.}
  HttpServer* = ref object of StreamServer
    callback: AsyncCallback

  HttpHeaders* = ref object
    table*: TableRef[string, seq[string]]

  HttpClient* = ref object
    connected: bool
    currentURL: Uri      ## Where we are currently connected.
    headers: HttpHeaders ## Headers to send in requests.
    transp*: StreamTransport
    buf: seq[byte]

  ReqStatus = enum
    Success, Error, ErrorFailure

  WebSocketError* = object of IOError

  Base16Error* = object of CatchableError
    ## Base16 specific exception type

template `[]`(value: uint8, index: int): bool =
  ## Get bits from uint8, uint8[2] gets 3rd bit.
  getBitBE(value, index)

proc genMaskKey(): array[4, char] =
  ## Generates a random key of 4 random chars.
  proc r(): char = char(rand(255))
  [r(), r(), r(), r()]

proc handshake*(ws: WebSocket, header: HttpRequestHeader) {.async.} =
  ## Handles the websocket handshake.
  ws.version = parseInt(header["Sec-WebSocket-Version"])
  ws.key = header["Sec-WebSocket-Key"].strip()
  if header.contains("Sec-WebSocket-Protocol"):
    let wantProtocol = header["Sec-WebSocket-Protocol"].strip()
    if ws.protocol != wantProtocol:
      raise newException(WebSocketError,
        "Protocol mismatch (expected: " & ws.protocol & ", got: " &
        wantProtocol & ")")

  let
    sh = secureHash(ws.key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    acceptKey = base64.encode(hexToByteArray[SHA1DigestSize]($sh))

  var response = "HTTP/1.1 101 Web Socket Protocol Handshake\c\L"
  response.add("Sec-WebSocket-Accept: " & acceptKey & "\c\L")
  response.add("Connection: Upgrade\c\L")
  response.add("Upgrade: webSocket\c\L")

  if ws.protocol != "":
    response.add("Sec-WebSocket-Protocol: " & ws.protocol & "\c\L")
  response.add "\c\L"

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
    var ws = WebSocket()
    ws.masked = false
    ws.protocol = protocol
    ws.tcpSocket = transp
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
    data: string ## Payload data

proc encodeFrame(f: Frame): seq[byte] =
  ## Encodes a frame into a string buffer.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  var ret = newSeqOfCap[byte](f.data.len + 14)

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
    let maskKey = genMaskKey()
    for i in 0..<data.len:
      data[i] = (data[i].uint8 xor maskKey[i mod 4].uint8).char
    # Write mask key next.
    ret.add(maskKey[0].uint8)
    ret.add(maskKey[1].uint8)
    ret.add(maskKey[2].uint8)
    ret.add(maskKey[3].uint8)

  # Write the data.
  ret.add(toBytes(data))
  return ret

proc send*(ws: WebSocket, datastr: string, opcode = Opcode.Text): Future[
    void] {.async.} =
  try:
    var frame = encodeFrame((
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: opcode,
      mask: ws.masked,
      data: datastr
    ))
    const maxSize = 1024*1024
    # Send stuff in 1 megabyte chunks to prevent IOErrors.
    # This really large packets.
    var i = 0
    while i < frame.len:
      let data = frame[i ..< min(frame.len, i + maxSize)]
      discard await ws.tcpSocket.write(data)
      i += maxSize
  except Defect, IOError, OSError, ValueError:
    # Wrap all exceptions in a WebSocketError so its easy to catch
    raise newException(WebSocketError, "Failed to send data: " &
        getCurrentExceptionMsg())

proc close*(ws: WebSocket) =
  ## Close the Socket, sends close packet.
  ws.readyState = Closed
  proc close() {.async.} =
    await ws.send("", Close)
    ws.tcpSocket.close()
  asyncCheck close()

proc receiveFrame(ws: WebSocket): Future[Frame] {.async.} =
  ## Gets a frame from the WebSocket.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  if cast[int](ws.tcpSocket.fd) == -1:
    ws.readyState = Closed
    raise newException(WebSocketError, "Socket closed")

  # Grab the header.
  var header = newSeq[byte](2)
  try:
    await ws.tcpSocket.readExactly(addr header[0], 2)
  except:
    raise newException(WebSocketError, "Socket closed")

  debug "Got a frame from the WebSocket"

  if header.len != 2:
    ws.readyState = Closed
    raise newException(WebSocketError, "Socket closed")

  let b0 = header[0].uint8
  let b1 = header[1].uint8

  # Read the flags and fin from the header.
  result.fin = b0[0]
  result.rsv1 = b0[1]
  result.rsv2 = b0[2]
  result.rsv3 = b0[3]
  result.opcode = (b0 and 0x0f).Opcode

  # If any of the rsv are set close the socket.
  if result.rsv1 or result.rsv2 or result.rsv3:
    ws.readyState = Closed
    raise newException(WebSocketError, "WebSocket rsv mismatch")

  # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
  var finalLen: uint = 0

  let headerLen = uint(b1 and 0x7f)
  if headerLen == 0x7e:
    # Length must be 7+16 bits.
    var length = newSeq[byte](2)
    await ws.tcpSocket.readExactly(addr length[0], 2)
    finalLen = cast[ptr uint16](length[0].addr)[].htons

  elif headerLen == 0x7f:
    # Length must be 7+64 bits.
    var length = newSeq[byte](8)
    await ws.tcpSocket.readExactly(addr length[0], 8)
    finalLen = cast[ptr uint32](length[4].addr)[].htonl

  else:
    # Length must be 7 bits.
    finalLen = headerLen

  # Do we need to apply mask?
  result.mask = (b1 and 0x80) == 0x80

  if ws.masked == result.mask:
    # Server sends unmasked but accepts only masked.
    # Client sends masked but accepts only unmasked.
    raise newException(WebSocketError, "Socket mask mismatch")

  var maskKey = newSeq[byte](4)
  if result.mask:
    # Read the mask.
    await ws.tcpSocket.readExactly(addr maskKey[0], 4)

  # Read the data.
  var data = newSeq[byte](finalLen)
  debug "Reading length:", length = finalLen
  await ws.tcpSocket.readExactly(addr data[0], int finalLen)
  debug "Done reading:", length = finalLen
  result.data = string.fromBytes(data)
  if result.data.len != int finalLen:
    raise newException(WebSocketError, "Socket closed")

  if result.mask:
    # Apply mask, if we need too.
    for i in 0 ..< result.data.len:
      result.data[i] = (result.data[i].uint8 xor maskKey[i mod 4].uint8).char

proc receivePacket*(ws: WebSocket): Future[(Opcode, string)] {.async.} =
  ## Wait for a string or binary packet to come in.
  var frame = await ws.receiveFrame()
  result[0] = frame.opcode
  result[1] = frame.data
  # If there are more parts read and wait for them
  while frame.fin != true:
    debug "Receiving more frame"
    frame = await ws.receiveFrame()
    if frame.opcode != Cont:
      raise newException(WebSocketError, "Socket closed")
    result[1].add frame.data
  return

proc receiveStrPacket*(ws: WebSocket): Future[string] {.async.} =
  ## Wait only for a string packet to come. Errors out on Binary packets.
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

proc sendHTTPResponse*(transp: StreamTransport, version: HttpVersion, code: HttpCode,
                data: string = ""): Future[bool] {.async.} =
  var answer = $version
  answer.add(" ")
  answer.add($code)
  answer.add("\r\n")
  answer.add("Date: " & httpDate() & "\r\n")
  if len(data) > 0:
    answer.add("Content-Type: application/json\r\n")
  answer.add("Content-Length: " & $len(data) & "\r\n")
  answer.add("\r\n")
  if len(data) > 0:
    answer.add(data)
  try:
    let res = await transp.write(answer)
    if res != len(answer):
      result = false
    result = true
  except:
    result = false

proc validateRequest(transp: StreamTransport,
                     header: HttpRequestHeader): Future[ReqStatus] {.async.} =
  if header.meth notin {MethodGet}:
    debug "GET method is only allowed", address = transp.remoteAddress()
    if await transp.sendHTTPResponse(header.version, Http405):
      result = Error
    else:
      result = ErrorFailure
    return

  if header.contentLength() > MaxHttpRequestSize:
    # request length is more then `MaxHttpRequestSize`.
    debug "Maximum size of request body reached",
          address = transp.remoteAddress()
    if await transp.sendHTTPResponse(header.version, Http413):
      result = Error
    else:
      result = ErrorFailure
    return

  result = Success

proc serveClient(server: StreamServer, transp: StreamTransport) {.async.} =
  ## Process transport data to the RPC server
  var httpServer = cast[HttpServer](server)
  var buffer = newSeq[byte](MaxHttpHeadersSize)
  var header: HttpRequestHeader

  info "Received connection", address = $transp.remoteAddress()
  try: # MaxHttpHeadersSize
    let hlenfut = transp.readUntil(addr buffer[0], MaxHttpHeadersSize,
        sep = HeaderSep)
    let ores = await withTimeout(hlenfut, HttpHeadersTimeout)
    if not ores:
      # Timeout
      debug "Timeout expired while receiving headers",
            address = transp.remoteAddress()
      discard await transp.sendHTTPResponse(HttpVersion11, Http408)
      await transp.closeWait()
      return
    else:
      let hlen = hlenfut.read()
      buffer.setLen(hlen)
      header = buffer.parseRequest()
      if header.failed():
        # Header could not be parsed
        debug "Malformed header received",
              address = transp.remoteAddress()
        discard await transp.sendHTTPResponse(HttpVersion11, Http400)
        await transp.closeWait()
        return
  except TransportLimitError:
    # size of headers exceeds `MaxHttpHeadersSize`
    debug "Maximum size of headers limit reached",
          address = transp.remoteAddress()
    discard await transp.sendHTTPResponse(HttpVersion11, Http413)
    await transp.closeWait()
    return
  except TransportIncompleteError:
    # remote peer disconnected
    debug "Remote peer disconnected", address = transp.remoteAddress()
    await transp.closeWait()
    return
  except TransportOsError as exc:
    debug "Problems with networking", address = transp.remoteAddress(),
          error = exc.msg
    await transp.closeWait()
    return
  except CatchableError as exc:
    debug "Unknown exception", address = transp.remoteAddress(),
          error = exc.msg
    await transp.closeWait()
    return

  let vres = await validateRequest(transp, header)
  if vres == Success:
    info "Received valid RPC request", address = $transp.remoteAddress()
    # Call the user's callback.
    if httpServer.callback != nil:
      await httpServer.callback(transp, header)
    await transp.closeWait()
  elif vres == ErrorFailure:
    debug "Remote peer disconnected", address = transp.remoteAddress()
    await transp.closeWait()

proc newHttpServer*(address: string, handler: AsyncCallback,
              flags: set[ServerFlags] = {ReuseAddr}): HttpServer =
  new result
  let address = initTAddress(address)
  result.callback = handler
  result = cast[HttpServer](createStreamServer(address, serveClient, flags,
      child = cast[StreamServer](result)))

func toTitleCase(s: string): string =
  result = newString(len(s))
  var upper = true
  for i in 0..len(s) - 1:
    result[i] = if upper: toUpperAscii(s[i]) else: toLowerAscii(s[i])
    upper = s[i] == '-'

func toCaseInsensitive*(headers: HttpHeaders, s: string): string {.inline.} =
  return toTitleCase(s)

func newHttpHeaders*(): HttpHeaders =
  ## Returns a new ``HttpHeaders`` object. if ``titleCase`` is set to true,
  ## headers are passed to the server in title case (e.g. "Content-Length")
  new result
  result.table = newTable[string, seq[string]]()

func newHttpHeaders*(keyValuePairs:
    openArray[tuple[key: string, val: string]]): HttpHeaders =
  ## Returns a new ``HttpHeaders`` object from an array. if ``titleCase`` is set to true,
  ## headers are passed to the server in title case (e.g. "Content-Length")
  new result
  result.table = newTable[string, seq[string]]()

  for pair in keyValuePairs:
    let key = result.toCaseInsensitive(pair.key)
    {.cast(noSideEffect).}:
      if key in result.table:
        result.table[key].add(pair.val)
      else:
        result.table[key] = @[pair.val]

proc generateHeaders(requestUrl: Uri, httpMethod: string,
    headers: HttpHeaders): string =
  # GET
  let upperMethod = httpMethod.toUpperAscii()
  result = upperMethod
  result.add ' '

  if not requestUrl.path.startsWith("/"): result.add '/'
  result.add(requestUrl.path)

  # HTTP/1.1\c\l
  result.add(" HTTP/1.1" & CRLF)

  for key, val in headers.table:
    add(result, key & ": " & val.join(", ") & CRLF)
  add(result, CRLF)

proc newHttpClient*(headers = newHttpHeaders()): HttpClient =
  new result
  result.headers = headers

proc close*(client: HttpClient) =
  ## Closes any connections held by the HTTP client.
  if client.connected:
    client.transp.close()
    client.connected = false

proc newConnection(client: HttpClient, url: Uri) {.async.} =
  if client.connected:
    return

  let port =
    if url.port == "":
        nativesockets.Port(80)
    else: nativesockets.Port(url.port.parseInt)

  client.transp = await connect(initTAddress(url.hostname, port))

  # May be connected through proxy but remember actual URL being accessed
  client.currentURL = url
  client.connected = true

proc validateWSClientHandshake*(transp: StreamTransport,
                       header: HttpResponseHeader): bool =
  if header.code != 101:
    debug "Server did not reply with a websocket upgrade: ",
          httpcode = header.code,
          httpreason = header.reason(),
          address = transp.remoteAddress()

  result = true

proc recvData(transp: StreamTransport): Future[string] {.async.} =
  var buffer = newSeq[byte](MaxHttpHeadersSize)
  var header: HttpResponseHeader
  var error = false
  try:
    let hlenfut = transp.readUntil(addr buffer[0], MaxHttpHeadersSize,
        sep = HeaderSep)
    let ores = await withTimeout(hlenfut, HttpHeadersTimeout)
    if not ores:
      # Timeout
      debug "Timeout expired while receiving headers",
             address = transp.remoteAddress()
      error = true
    else:
      let hlen = hlenfut.read()
      buffer.setLen(hlen)
      header = buffer.parseResponse()
      if header.failed():
        # Header could not be parsed
        debug "Malformed header received",
              address = transp.remoteAddress()
        error = true
  except TransportLimitError:
    # size of headers exceeds `MaxHttpHeadersSize`
    debug "Maximum size of headers limit reached",
          address = transp.remoteAddress()
    error = true
  except TransportIncompleteError:
    # remote peer disconnected
    debug "Remote peer disconnected", address = transp.remoteAddress()
    error = true
  except TransportOsError as exc:
    debug "Problems with networking", address = transp.remoteAddress(),
          error = exc.msg
    error = true

  if error or not transp.validateWSClientHandshake(header):
    result = ""
    return

  if error:
    result = ""
  else:
    result = cast[string](buffer)

# Send request to the client. Currently only supports HTTP get method.
proc request*(client: HttpClient, url, httpMethod: string,
             body = "", headers: HttpHeaders = nil): Future[string]
             {.async.} =
  # Helper that actually makes the request. Does not handle redirects.
  let requestUrl = parseUri(url)
  if requestUrl.scheme == "":
    raise newException(ValueError, "No uri scheme supplied.")

  await newConnection(client, requestUrl)

  let headerString = generateHeaders(requestUrl, httpMethod, headers)
  let res = await client.transp.write(headerString)
  if res != len(headerString):
    raise newException(WebSocketError, "Error while send request to client.")

  debug "Request sent for websocket handshake"
  var value = await client.transp.recvData()
  if value.len == 0:
    raise newException(ValueError, "Empty response from server")

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
  discard await client.request($uri, "GET", headers = headers)

  new(result)
  result.tcpSocket = client.transp
  result.readyState = Open
  result.masked = true # Client data should be masked.

proc newWebsocketClient*(host: string, port: Port, path: string,
    protocols: seq[string] = @[]): Future[WebSocket] {.async.} =
  var uri = "ws://" & host & ":" & $port
  if path.startsWith("/"):
    uri.add path
  else:
    uri.add "/" & path
  result = await newWebsocketClient(parseUri(uri), protocols)
