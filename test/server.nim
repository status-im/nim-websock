import ws, chronos, chronicles, httputils

proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
  info "Received Connection", uri = header.uri()
  if header.uri() == "/ws":
    info "Initiating web socket connection."
    try:
      var ws = await newWebSocket(header, transp, "myfancyprotocol")
      if ws.readyState == Open:
        info "Websocket handshake completed."
      else:
        error "Failed to open websocket connection."
        return

      while ws.readyState == Open:
        let recvData = await ws.receiveStrPacket()
        info "Client:", data = recvData
        await ws.send(recvData)
    except WebSocketError:
      error "WebSocket error:", exception = getCurrentExceptionMsg()

  discard await transp.sendHTTPResponse(HttpVersion11, Http200, "Hello World")
  await transp.closeWait()

when isMainModule:
  let address = "127.0.0.1:8888"
  var httpServer = newHttpServer(address, cb)
  httpServer.start()
  waitFor httpServer.join()
