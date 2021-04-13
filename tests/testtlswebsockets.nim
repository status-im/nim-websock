import std/strutils, httputils

import pkg/[asynctest,
            chronos,
            chronos/apps/http/shttpserver,
            stew/byteutils]

import  ../ws/[ws, stream],
        ../examples/tlsserver

import ./keys

var server: SecureHttpServerRef
let address = initTAddress("127.0.0.1:8888")
let serverFlags  = {HttpServerFlags.Secure, HttpServerFlags.NotifyDisconnect}
let socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
let clientFlags = {NoVerifyHost, NoVerifyServerName}

let secureKey = TLSPrivateKey.init(SecureKey)
let secureCert = TLSCertificate.init(SecureCert)

suite "Test websocket TLS handshake":
  teardown:
    await server.closeWait()

  test "Test for websocket TLS incorrect protocol":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return

      let request = r.get()
      check request.uri.path == "/wss"
      expect WSProtoMismatchError:
          var ws = await createServer(request, "proto")
          check ws.readyState == ReadyState.Closed

      return await request.respond(Http200, "Connection established")

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
        return

      let request = r.get()
      check request.uri.path == "/wss"
      expect WSVersionError:
          var ws = await createServer(request, "proto")
          check ws.readyState == ReadyState.Closed

      return await request.respond(Http200, "Connection established")

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
      check request.headers.getString("Connection").toUpperAscii() == "Upgrade".toUpperAscii()
      check request.headers.getString("Upgrade").toUpperAscii() == "websocket".toUpperAscii()
      check request.headers.getString("Cache-Control").toUpperAscii() == "no-cache".toUpperAscii()
      check request.headers.getString("Sec-WebSocket-Version") == $WSDefaultVersion

      check request.headers.contains("Sec-WebSocket-Key")

      discard await request.respond( Http200,"Connection established")

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
      let ws = await createServer(request, "proto")
      let servRes = await ws.recv()
      check string.fromBytes(servRes) == testString
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

    await wsClient.send(testString)
    await wsClient.close()

  test "Client - test reading simple frame":
    let testString = "Hello!"
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/wss"
      let ws = await createServer(request, "proto")
      let servRes = await ws.recv()
      check string.fromBytes(servRes) == testString
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

    await wsClient.send(testString)
    await wsClient.close()

  test "Client - test reading simple frame":
    let testString = "Hello!"
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/wss"
      let ws = await createServer(request, "proto")
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

    var clientRes = await wsClient.recv()
    check string.fromBytes(clientRes) == testString
    await wsClient.close()
