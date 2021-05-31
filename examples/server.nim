
import std/uri
import pkg/[chronos,
             chronicles,
             httputils]

import ../ws/ws

proc handle(request: HttpRequest) {.async.} =
  debug "Handling request:", uri = request.uri.path
  if request.uri.path != "/ws":
    return

  debug "Initiating web socket connection."
  try:
    let server = WSServer.new()
    let ws = await server.handleRequest(request)
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
      await ws.send(recvData,
        if ws.binary: Opcode.Binary else: Opcode.Text)
  except WebSocketError as exc:
    error "WebSocket error:", exception = exc.msg

when isMainModule:
  proc main() {.async.} =
    let
      address = initTAddress("127.0.0.1:8888")
      socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
      server = HttpServer.create(address, handle, flags = socketFlags)

    server.start()
    info "Server listening at ", data = $server.localAddress()
    await server.join()

  waitFor(main())
