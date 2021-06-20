## nim-ws
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/uri
import pkg/[chronos,
             chronicles,
             httputils]

import ../ws/ws
import ../tests/keys

proc handle(request: HttpRequest) {.async.} =
  trace "Handling request:", uri = request.uri.path
  let path = when defined tls: "/wss" else: "/ws"
  if request.uri.path != path:
    return

  trace "Initiating web socket connection."
  try:
    let server = WSServer.new()
    let ws = await server.handleRequest(request)
    if ws.readyState != Open:
      error "Failed to open websocket connection"
      return

    trace "Websocket handshake completed"
    while ws.readyState != ReadyState.Closed:
      let recvData = await ws.recv()

      trace "Client Response: ", size = recvData.len, binary = ws.binary
      await ws.send(recvData,
        if ws.binary: Opcode.Binary else: Opcode.Text)

  except WebSocketError as exc:
    error "WebSocket error:", exception = exc.msg

when isMainModule:
  # we want to run parallel tests in CI
  # so we are using different port
  const serverAddr = when defined tls:
                       "127.0.0.1:8889"
                     else:
                       "127.0.0.1:8888"

  proc main() {.async.} =
    let
      address = initTAddress(serverAddr)
      socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
      server = when defined tls:
        TlsHttpServer.create(
          address = address,
          handler = handle,
          tlsPrivateKey = TLSPrivateKey.init(SecureKey),
          tlsCertificate = TLSCertificate.init(SecureCert),
          flags = socketFlags)
      else:
        HttpServer.create(address, handle, flags = socketFlags)

    server.start()
    trace "Server listening on ", data = $server.localAddress()
    await server.join()

  waitFor(main())
