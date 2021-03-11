import ../src/ws, ../src/http, chronos, chronicles, httputils, stew/byteutils

proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
  info "Handling request:", uri = header.uri()
  if header.uri() == "/ws":
    info "Initiating web socket connection."
    try:
      var ws = await newWebSocket(header, transp, "myfancyprotocol")
      if ws.readyState == Open:
        info "Websocket handshake completed."
      else:
        error "Failed to open websocket connection."
        return

      while true:
        # Only reads header for data frame.
        let msgReader = await ws.nextMessageReader()

        # Read the frame payload in buffer.
        let buffer = newSeq[byte](100)
        var recvData :seq[byte]
        while msgReader.error != EOFError:
          msgReader.readMessage(buffer)
          recvData.add buffer
          if ws.readyState == ReadyState.Closed:
            return
        info "Response: ",  data = recvData
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
