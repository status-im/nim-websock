import pkg/[chronos,
            chronicles,
            httputils,
            stew/byteutils]

import pkg/[chronos/streams/tlsstream]

import ../ws/ws
import ../tests/keys

proc handle(request: HttpRequest) {.async.} =
  debug "Handling request:", uri = request.uri.path
  if request.uri.path != "/wss":
    debug "Initiating web socket connection."
    return

  try:
    let server = WSServer.new(protos = ["myfancyprotocol"])
    var ws = await server.handleRequest(request)
    if ws.readyState != Open:
        error "Failed to open websocket connection."
        return
    debug "Websocket handshake completed."
    # Only reads header for data frame.
    echo "receiving server "
    let recvData = await ws.recv()
    if recvData.len <= 0:
        debug "Empty messages"
        break

    if ws.readyState == ReadyState.Closed:
        return
    debug "Response: ", data = string.fromBytes(recvData)
    await ws.send(recvData,
        if ws.binary: Opcode.Binary else: Opcode.Text)
  except WebSocketError:
      error "WebSocket error:", exception = getCurrentExceptionMsg()

when isMainModule:
  proc main() {.async.} =
    let address = initTAddress("127.0.0.1:8888")
    let socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
    let server = TlsHttpServer.create(
        address = address,
        handler = handle,
        tlsPrivateKey = TLSPrivateKey.init(SecureKey),
        tlsCertificate = TLSCertificate.init(SecureCert),
        flags = socketFlags)

    server.start()
    info "Server listening at ", data = $server.localAddress()
    await server.join()

  waitFor(main())