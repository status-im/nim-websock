import pkg/[chronos,
             chronos/apps/http/httpserver,
             chronicles,
             httputils]

import ../ws/ws

proc process(r: RequestFence): Future[HttpResponseRef] {.async.} =
  if r.isOk():
    let request = r.get()
    debug "Handling request:", uri = request.uri.path
    if request.uri.path == "/ws":
      debug "Initiating web socket connection."
      try:
        let ws = await createServer(request, "")
        if ws.readyState != Open:
          error "Failed to open websocket connection."
          return
        debug "Websocket handshake completed."
        while true:
          let recvData = await ws.recv()
          if ws.readyState == ReadyState.Closed:
            debug "Websocket closed."
            break
          debug "Client Response: ", size = recvData.len
          await ws.send(recvData)

      except WebSocketError as exc:
        error "WebSocket error:", exception = exc.msg

    let header = HttpTable.init([
      ("Server", "nim-ws example server")
    ])

    discard await request.respond(Http200, "Hello World")
  else:
    return dumbResponse()

when isMainModule:
  let address = initTAddress("127.0.0.1:8888")
  let socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
  let res = HttpServerRef.new(
    address, process,
    socketFlags = socketFlags)

  let server = res.get()
  server.start()
  info "Server listening at ", data = address
  waitFor server.join()
