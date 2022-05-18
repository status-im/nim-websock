import testutils/fuzzing
import chronos
import ../../websock/websock
import ../keys

proc waitForClose*(ws: WSSession) {.async.} =
  try:
    while ws.readyState != ReadyState.Closed:
      discard await ws.recvMsg()
  except CatchableError:
    trace "Closing websocket"

proc createServer*(
  address = initTAddress("127.0.0.1:8888"),
  tlsPrivateKey = TLSPrivateKey.init(SecureKey),
  tlsCertificate = TLSCertificate.init(SecureCert),
  handler: HttpAsyncCallback = nil,
  flags: set[ServerFlags] = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr},
  tlsFlags: set[TLSFlags] = {},
  tlsMinVersion = TLSVersion.TLS12,
  tlsMaxVersion = TLSVersion.TLS12): HttpServer
  {.raises: [Defect, HttpError].} =
  try:
    let server = when defined secure:
      TlsHttpServer.create(
        address = address,
        tlsPrivateKey = tlsPrivateKey,
        tlsCertificate = tlsCertificate,
        flags = flags,
        tlsFlags = tlsFlags,
        handshakeTimeout = 20.milliseconds,
        headersTimeout = 10.milliseconds,
        tlsMinVersion = tlsMinVersion,
        tlsMaxVersion = tlsMaxVersion)
    else:
      HttpServer.create(
        address = address,
        handshakeTimeout = 20.milliseconds,
        headersTimeout = 10.milliseconds,
        flags = flags)

    when defined accepts:
      proc accepts() {.async, raises: [Defect].} =
        try:
          let req = await server.accept()
          await req.handler()
        except TransportOsError as exc:
          error "Transport error", exc = exc.msg

      asyncSpawn accepts()
    else:
      server.handler = handler
      server.start()

    return server
  except CatchableError as exc:
    raise newException(Defect, exc.msg)


test:
  var server: HttpServer

  proc handle(request: HttpRequest) {.async.} =
    let server = WSServer.new(protos = ["proto"])
    let ws = await server.handleRequest(request)
    let servRes = await ws.recvMsg()

    await ws.waitForClose()

  server = createServer(
    address = initTAddress("0.0.0.0:0"),
    handler = handle,
    flags = {ReuseAddr})

  let conn = waitFor(connect(server.localAddress(), 4096, nil))

  let pdseq = @payload
  if pdseq.len > 0:
    discard waitFor(conn.write(pdseq))
    var buf = newSeq[byte](1000)
    discard waitFor(conn.readOnce(addr buf[0], 1000))
  waitFor(conn.closeWait())

  server.stop()
  waitFor(server.closeWait())
