import ../src/ws, ../src/http, chronos, chronicles, httputils, stew/byteutils

proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
  info "Handling request:", uri = header.uri()
  if header.uri() == "/ws":
    info "Initiating web socket connection."
    try:
      var ws = await createServer(header, transp, "myfancyprotocol")
      if ws.readyState != Open:
        error "Failed to open websocket connection."
        return

      info "Websocket handshake completed."
      while true:
        # Only reads header for data frame.
        var buffer = newSeq[byte](100)
        var recvData: seq[byte]
        let read = await ws.recv(addr buffer[0], buffer.len)
        recvData.add(buffer)
        if read <= 0:
          break

        if ws.readyState == ReadyState.Closed:
          return

        recvData.setLen(read)
        info "Response: ", data = string.fromBytes(recvData)
        await ws.send(recvData)

    except WebSocketError:
      error "WebSocket error:", exception = getCurrentExceptionMsg()

  discard await transp.sendHTTPResponse(HttpVersion11, Http200, "Hello World")
  await transp.closeWait()

when isMainModule:
  let address = "127.0.0.1:8888"
  var httpServer = newHttpServer(address, cb)
  httpServer.start()
  echo "Server started..."
  waitFor httpServer.join()
