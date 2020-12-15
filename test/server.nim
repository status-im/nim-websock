import ws, chronos, chronicles, httputils

proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
  info "Header: ", uri = header.uri()
  if header.uri() == "/ws":
    info "Initiating web socket connection."
    try:
      var ws = await newWebSocket(header, transp)
      echo await ws.receivePacket()
      info "Websocket handshake completed."
    except WebSocketError:
      echo "socket closed:", getCurrentExceptionMsg()

  let res = await transp.sendHTTPResponse(HttpVersion11, Http200, "Hello World")

when isMainModule:
  let address = "127.0.0.1:8888"
  var httpServer = newHttpServer(address, cb)
  httpServer.start()
  waitFor httpServer.join()
