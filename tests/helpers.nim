import ../src/ws, chronos, chronicles, httputils, stew/byteutils,
    ../src/http, unittest, strutils

proc echoCb*(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
  info "Handling request:", uri = header.uri()
  if header.uri() == "/ws":
    info "Initiating web socket connection."
    try:
      var ws = await createServer(header, transp, "myfancyprotocol")
      if ws.readyState == Open:
        info "Websocket handshake completed."
      else:
        error "Failed to open websocket connection."
        return

      let recvData = await ws.recv()
      info "Server:", state = ws.readyState
      await ws.send(recvData)
    except WebSocketError:
      error "WebSocket error:", exception = getCurrentExceptionMsg()
  discard await transp.sendHTTPResponse(HttpVersion11, Http200, "Connection established")

proc sendRecvClientData*(wsClient: WebSocket, msg: string) {.async.} =
  try:
    await wsClient.send(msg)
    let recvData = await wsClient.recv()
    info "Websocket client state: ", state = wsClient.readyState
    let dataStr = string.fromBytes(recvData)
    require dataStr == msg

  except WebSocketError:
    error "WebSocket error:", exception = getCurrentExceptionMsg()

proc incorrectProtocolCB*(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
    info "Handling request:", uri = header.uri()
    var isErr = false;
    if header.uri() == "/ws":
        info "Initiating web socket connection."
        try:
            var ws = await createServer(header, transp, "myfancyprotocol")
            require ws.readyState == ReadyState.Closed
        except WebSocketError:
            isErr = true;
            require contains(getCurrentExceptionMsg(), "Protocol mismatch")
        finally:
            require isErr == true
    discard await transp.sendHTTPResponse(HttpVersion11, Http200, "Connection established")


proc generateData*(num: int64): seq[byte] =
  var str = newSeqOfCap[byte](num)
  for i in 0 ..< num:
    str.add(65)
  return str
