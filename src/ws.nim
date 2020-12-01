import chronos, asynchttpserver, base64, nativesockets

type HeaderVerificationError* {.pure.} = enum
  None
    ## No error.
  UnsupportedVersion
    ## The Sec-Websocket-Version header gave an unsupported version.
    ## The only currently supported version is 13.
  NoKey
    ## No Sec-Websocket-Key was provided.
  ProtocolAdvertised
    ## A protocol was advertised but the server gave no protocol.
  NoProtocolsSupported
    ## None of the advertised protocols match the server protocol.
  NoProtocolAdvertised
    ## Server asked for a protocol but no protocol was advertised.

proc `$`*(error: HeaderVerificationError): string =
  const errorTable: array[HeaderVerificationError, string] = [
    "no error",
    "the only supported sec-websocket-version is 13",
    "no sec-websocket-key provided",
    "server does not support protocol negotation",
    "no advertised protocol supported",
    "no protocol advertised"
  ]
  result = errorTable[error]

type
  ReadyState* = enum
    Connecting = 0 # The connection is not yet open.
    Open = 1       # The connection is open and ready to communicate.
    Closing = 2    # The connection is in the process of closing.
    Closed = 3     # The connection is closed or couldn't be opened.

  WebSocket* = ref object
    tcpSocket*: AsyncSocket
    version*: int
    key*: string
    protocol*: string
    readyState*: ReadyState
    masked*: bool # send masked packets

  WebSocketError* = object of IOError

proc handshake*(ws: WebSocket, headers: HttpHeaders): Future[error: HeaderVerificationError] {.async.} =
  ws.version = parseInt(headers["Sec-WebSocket-Version"])
  ws.key = headers["Sec-WebSocket-Key"].strip()
  if headers.hasKey("Sec-WebSocket-Protocol"):
    let wantProtocol = headers["Sec-WebSocket-Protocol"].strip()
    if ws.protocol != wantProtocol:
      return NoProtocolsSupported

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

  await ws.tcpSocket.send(response)
  ws.readyState = Open

proc newWebSocket*(req: Request, protocol: string = ""): Future[tuple[ws: AsyncWebSocket, error: HeaderVerificationError]] {.async.} =
  if not req.headers.hasKey("Sec-WebSocket-Version"):
    return ("", UnsupportedVersion)

  var ws = WebSocket()
  ws.masked = false
  # Todo: Change this to chronos AsyncFD
  ws.tcpSocket = req.client
  ws.protocol = protocol
  let (ws, error) = await ws.handshake(req.headers)
  return ws, error

proc close*(ws: WebSocket) =
  ws.readyState = Closed
  proc close() {.async.} =
    await ws.send("", Close)
    ws.tcpSocket.close()
  asyncCheck close()
