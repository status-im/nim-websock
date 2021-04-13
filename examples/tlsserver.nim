import pkg/[chronos,
            chronos/apps/http/shttpserver,
            chronicles,
            httputils,
            stew/byteutils]

import ../ws/ws
import ../tests/keys

let secureKey = TLSPrivateKey.init(SecureKey)
let secureCert = TLSCertificate.init(SecureCert)

proc process(r: RequestFence): Future[HttpResponseRef] {.async.} =
    if r.isOk():
        let request = r.get()

        debug "Handling request:", uri = request.uri.path
        if request.uri.path == "/wss":
            debug "Initiating web socket connection."
            try:
                var ws = await createServer(request, "myfancyprotocol")
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
                await ws.send(recvData)
            except WebSocketError:
                error "WebSocket error:", exception = getCurrentExceptionMsg()
        discard await request.respond(Http200, "Hello World")
    else:
        return dumbResponse()

when isMainModule:
    let address = initTAddress("127.0.0.1:8888")
    let serverFlags  = {Secure, NotifyDisconnect}
    let socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
    let res = SecureHttpServerRef.new(
        address, process,
        serverFlags = serverFlags,
        socketFlags = socketFlags,
        tlsPrivateKey = secureKey,
        tlsCertificate = secureCert)

    let server = res.get()
    server.start()
    info "Server listening at ", data = address
    waitFor server.join()
