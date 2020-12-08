import chronos, chronicles, httputils, strutils, base64, std/sha1, random

const
  MaxHttpHeadersSize = 8192        # maximum size of HTTP headers in octets
  MaxHttpRequestSize = 128 * 1024  # maximum size of HTTP body in octets
  HttpHeadersTimeout = 120.seconds # timeout for receiving headers (120 sec)
  HttpBodyTimeout = 12.seconds     # timeout for receiving body (12 sec)
  HeadersMark = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]

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

  ReqStatus = enum
    Success, Error, ErrorFailure

  WebSocketError* = object of IOError

template `[]`(value: uint8, index: int): bool =
  ## Get bits from uint8, uint8[2] gets 2nd bit.
  (value and (1 shl (7 - index))) != 0

proc nibbleFromChar(c: char): int =
  ## Converts hex chars like `0` to 0 and `F` to 15.
  case c:
    of '0'..'9': (ord(c) - ord('0'))
    of 'a'..'f': (ord(c) - ord('a') + 10)
    of 'A'..'F': (ord(c) - ord('A') + 10)
    else: 255

proc nibbleToChar(value: int): char =
  ## Converts number like 0 to `0` and 15 to `fg`.
  case value:
    of 0..9: char(value + ord('0'))
    else: char(value + ord('a') - 10)

proc decodeBase16*(str: string): string =
  ## Base16 decode a string.
  result = newString(str.len div 2)
  for i in 0 ..< result.len:
    result[i] = chr(
      (nibbleFromChar(str[2 * i]) shl 4) or
      nibbleFromChar(str[2 * i + 1]))

proc encodeBase16*(str: string): string =
  ## Base61 encode a string.
  result = newString(str.len * 2)
  for i, c in str:
    result[i * 2] = nibbleToChar(ord(c) shr 4)
    result[i * 2 + 1] = nibbleToChar(ord(c) and 0x0f)

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
        "Protocol mismatch (expected: " & ws.protocol & ", got: " & wantProtocol & ")")

  let
    sh = secureHash(ws.key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    acceptKey = base64.encode(decodeBase16($sh))

  var response = "HTTP/1.1 101 Web Socket Protocol Handshake\c\L"
  response.add("Sec-WebSocket-Accept: " & acceptKey & "\c\L")
  response.add("Connection: Upgrade\c\L")
  response.add("Upgrade: webSocket\c\L")

  if ws.protocol != "":
    response.add("Sec-WebSocket-Protocol: " & ws.protocol & "\c\L")
  response.add "\c\L"

  discard await ws.tcpSocket.write(response)
  ws.readyState = Open

proc newWebSocket*(header: HttpRequestHeader, transp: StreamTransport, protocol: string = ""): Future[
    WebSocket] {.async.} =
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
    # Request method is either PUT or DELETE.
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
  var connection: string

  info "Received connection", address = $transp.remoteAddress()
  try:
    let hlenfut = transp.readUntil(addr buffer[0], MaxHttpHeadersSize, HeadersMark)
    let ores = await withTimeout(hlenfut, HttpHeadersTimeout)
    if not ores:
      # Timeout
      debug "Timeout expired while receiving headers",
            address = transp.remoteAddress()
      let res = await transp.sendHTTPResponse(HttpVersion11, Http408)
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
        let res = await transp.sendHTTPResponse(HttpVersion11, Http400)
        await transp.closeWait()
        return
  except TransportLimitError:
    # size of headers exceeds `MaxHttpHeadersSize`
    debug "Maximum size of headers limit reached",
          address = transp.remoteAddress()
    let res = await transp.sendHTTPResponse(HttpVersion11, Http413)
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
    trace "Received valid RPC request", address = $transp.remoteAddress()

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
