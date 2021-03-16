import ../src/ws, ../src/http, chronos, chronicles, httputils, stew/byteutils

proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
  debug "Handling request:", uri = header.uri()
  if header.uri() == "/ws":
    debug "Initiating web socket connection."
    try:
      var ws = await createServer(header, transp, "")
      if ws.readyState != Open:
        error "Failed to open websocket connection."
        return

      debug "Websocket handshake completed."
      while ws.readyState == Open:
        # Only reads header for data frame.
        var recvData = await ws.recv()
        if ws.readyState == ReadyState.Closed:
          debug "Websockets closed"
          break

        if recvData.len <= 0:
          debug "Empty messages"
          break

        # debug "Response: ", data = string.fromBytes(recvData), size = recvData.len
        debug "Response: ", size = recvData.len
        await ws.send(recvData)

    except WebSocketError as exc:
      error "WebSocket error:", exception = exc.msg

  discard await transp.sendHTTPResponse(HttpVersion11, Http200, "Hello World")
  await transp.closeWait()

when isMainModule:
  let address = "127.0.0.1:8888"
  var httpServer = newHttpServer(address, cb)
  httpServer.start()
  echo "Server started..."
  waitFor httpServer.join()
