import std/strutils, httputils

import pkg/[asynctest,
            chronos,
            chronicles,
            chronos/apps/http/shttpserver,
            stew/byteutils]

import ../ws/[ws, stream, errors],
        ../examples/tlsserver

import ./keys

proc waitForClose(ws: WebSocket) {.async.} =
  try:
    while ws.readystate != ReadyState.Closed:
      discard await ws.recv()
  except CatchableError:
    debug "Closing websocket"

var server: SecureHttpServerRef

let
  address = initTAddress("127.0.0.1:8888")
  serverFlags = {HttpServerFlags.Secure, HttpServerFlags.NotifyDisconnect}
  socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
  clientFlags = {NoVerifyHost, NoVerifyServerName}
  secureKey = TLSPrivateKey.init(SecureKey)
  secureCert = TLSCertificate.init(SecureCert)

suite "Test websocket TLS handshake":
  teardown:
    await server.closeWait()

  test "Test for websocket TLS incorrect protocol":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/wss"
      expect WSProtoMismatchError:
        discard await WebSocket.createServer(request, "proto")

    let res = SecureHttpServerRef.new(
      address, cb,
      serverFlags = serverFlags,
      socketFlags = socketFlags,
      tlsPrivateKey = secureKey,
      tlsCertificate = secureCert)

    server = res.get()
    server.start()

    expect WSFailedUpgradeError:
      discard await WebSocket.tlsConnect(
        "127.0.0.1",
        Port(8888),
        path = "/wss",
        protocols = @["wrongproto"],
        clientFlags)

  test "Test for websocket TLS incorrect version":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/wss"
      expect WSVersionError:
        discard await WebSocket.createServer(request, "proto")

    let res = SecureHttpServerRef.new(
      address, cb,
      serverFlags = serverFlags,
      socketFlags = socketFlags,
      tlsPrivateKey = secureKey,
      tlsCertificate = secureCert)

    server = res.get()
    server.start()

    expect WSFailedUpgradeError:
      discard await WebSocket.tlsConnect(
        "127.0.0.1",
        Port(8888),
        path = "/wss",
        protocols = @["wrongproto"],
        clientFlags,
        version = 14)

  test "Test for websocket TLS client headers":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/wss"
      check request.headers.getString("Connection").toUpperAscii() ==
          "Upgrade".toUpperAscii()
      check request.headers.getString("Upgrade").toUpperAscii() ==
          "websocket".toUpperAscii()
      check request.headers.getString("Cache-Control").toUpperAscii() ==
          "no-cache".toUpperAscii()
      check request.headers.getString("Sec-WebSocket-Version") == $WSDefaultVersion

      check request.headers.contains("Sec-WebSocket-Key")
      discard await request.respond(Http200, "Connection established")

    let res = SecureHttpServerRef.new(
      address, cb,
      serverFlags = serverFlags,
      socketFlags = socketFlags,
      tlsPrivateKey = secureKey,
      tlsCertificate = secureCert)

    server = res.get()
    server.start()

    expect WSFailedUpgradeError:
      discard await WebSocket.tlsConnect(
        "127.0.0.1",
        Port(8888),
        path = "/wss",
        protocols = @["proto"],
        clientFlags)

suite "Test websocket TLS transmission":
  teardown:
    await server.closeWait()

  test "Server - test reading simple frame":
    let testString = "Hello!"
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/wss"
      let ws = await WebSocket.createServer(request, "proto")
      let servRes = await ws.recv()
      check string.fromBytes(servRes) == testString
      await waitForClose(ws)
      return dumbResponse()

    let res = SecureHttpServerRef.new(
      address, cb,
      serverFlags = serverFlags,
      socketFlags = socketFlags,
      tlsPrivateKey = secureKey,
      tlsCertificate = secureCert)

    server = res.get()
    server.start()

    let wsClient = await WebSocket.tlsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/wss",
      protocols = @["proto"],
      clientFlags)

    await wsClient.send(testString)
    await wsClient.close()

  test "Client - test reading simple frame":
    let testString = "Hello!"
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/wss"
      let ws = await WebSocket.createServer(request, "proto")
      await ws.send(testString)
      await ws.close()
      return dumbResponse()

    let res = SecureHttpServerRef.new(
      address, cb,
      serverFlags = serverFlags,
      socketFlags = socketFlags,
      tlsPrivateKey = secureKey,
      tlsCertificate = secureCert)

    server = res.get()
    server.start()

    let wsClient = await WebSocket.tlsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/wss",
      protocols = @["proto"],
      clientFlags)

    let clientRes = await wsClient.recv()
    check string.fromBytes(clientRes) == testString
    await waitForClose(wsClient)
