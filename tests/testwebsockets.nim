import std/strutils,httputils

import pkg/[asynctest,
            chronos,
            chronos/apps/http/httpserver,
            stew/byteutils]

import  ../ws/[ws, stream]

var server: HttpServerRef
let address = initTAddress("127.0.0.1:8888")

suite "Test handshake":
  teardown:
    await server.stop()
    await server.closeWait()

  test "Test for incorrect protocol":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return

      let request = r.get()
      check request.uri.path == "/ws"
      expect WSProtoMismatchError:
        var ws = await createServer(request, "proto")
        check ws.readyState == ReadyState.Closed

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    expect WSFailedUpgradeError:
      discard await WebSocket.connect(
        "127.0.0.1",
        Port(8888),
        path = "/ws",
        protocols = @["wrongproto"])

  test "Test for incorrect version":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return

      let request = r.get()
      check request.uri.path == "/ws"
      expect WSVersionError:
        var ws = await createServer(request, "proto")
        check ws.readyState == ReadyState.Closed

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    expect WSFailedUpgradeError:
      discard await WebSocket.connect(
        "127.0.0.1",
        Port(8888),
        path = "/ws",
        protocols = @["wrongproto"],
        version = 14)

  test "Test for client headers":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return

      let request = r.get()
      check request.uri.path == "/ws"
      check request.headers.getString("Connection").toUpperAscii() == "Upgrade".toUpperAscii()
      check request.headers.getString("Upgrade").toUpperAscii() == "websocket".toUpperAscii()
      check request.headers.getString("Cache-Control").toUpperAscii() == "no-cache".toUpperAscii()
      check request.headers.getString("Sec-WebSocket-Version") == $WSDefaultVersion

      check request.headers.contains("Sec-WebSocket-Key")

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    expect WSFailedUpgradeError:
      discard await WebSocket.connect(
        "127.0.0.1",
        Port(8888),
        path = "/ws",
        protocols = @["proto"])

  test "Test for incorrect scheme":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return

      let request = r.get()
      check request.uri.path == "/ws"

      expect WSProtoMismatchError:
        var ws = await createServer(request, "proto")
        check ws.readyState == ReadyState.Closed

      return await request.respond(Http200, "Connection established")

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let uri = "wx://127.0.0.1:8888/ws"
    expect WSWrongUriSchemeError:
      discard await WebSocket.connect(
        parseUri(uri),
        protocols = @["proto"])

suite "Test transmission":
  teardown:
    await server.closeWait()

  test "Server - test reading simple frame":
    let testString = "Hello!"
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      let servRes = await ws.recv()

      check string.fromBytes(servRes) == testString
      await ws.close()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
    await wsClient.send(testString)
    await wsClient.close()

  test "Client - test reading simple frame":
    let testString = "Hello!"
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      if r.isErr():
        return

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      await ws.send(testString)
      await ws.close()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    var clientRes = await wsClient.recv()
    await wsClient.close()
    check string.fromBytes(clientRes) == testString

suite "Test ping-pong":
  teardown:
    await server.closeWait()

  test "Server - test ping-pong control messages":
    var ping, pong = false
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      if r.isErr():
        return

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(
        request,
        "proto",
        onPong = proc() =
          pong = true
        )

      await ws.ping()
      await ws.close()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onPing = proc() =
        ping = true
      )

    discard await wsClient.recv()
    check:
      ping
      pong

  test "Client - test ping-pong control messages":
    var ping, pong = false
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      if r.isErr():
        return

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(
        request,
        "proto",
        onPing = proc() =
          ping = true
        )

      discard await ws.recv()
      await ws.close()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onPong = proc() =
        pong = true
      )

    await wsClient.ping()
    await wsClient.close()
    check:
      ping
      pong

suite "Test framing":
  teardown:
    await server.closeWait()

  test "should split message into frames":
    let testString = "1234567890"
    proc cb(r: RequestFence): Future[HttpResponseRef]{.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"

      let ws = await createServer(request, "proto")
      let frame1 = await ws.readFrame()
      check not isNil(frame1)
      var data1 = newSeq[byte](frame1.remainder().int)
      let read1 = await ws.stream.reader.readOnce(addr data1[0], data1.len)
      check read1 == 5

      let frame2 = await ws.readFrame()
      check not isNil(frame2)
      var data2 = newSeq[byte](frame2.remainder().int)
      let read2 = await ws.stream.reader.readOnce(addr data2[0], data2.len)
      check read2 == 5

      await ws.close()
      return dumbResponse()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      frameSize = 5)

    await wsClient.send(testString)
    await wsClient.close()

  test "should fail to read past max message size":
    let testString = "1234567890"
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async, gcsafe.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      await ws.send(testString)
      await ws.close()
      return dumbResponse()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    expect WSMaxMessageSizeError:
      discard await wsClient.recv(5)

    await wsClient.close()

suite "Test Closing":
  teardown:
    await server.closeWait()

  test "Server closing":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      await ws.close()
      return dumbResponse()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    discard await wsClient.recv()
    check wsClient.readyState == ReadyState.Closed

  test "Server closing with status":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      proc closeServer(status: Status, reason: string): CloseResult
        {.gcsafe, raises: [Defect].} =
        try:
          check status == Status.TooLarge
          check reason == "Message too big!"
        except Exception as exc:
          raise newException(Defect, exc.msg)

        return (Status.Fulfilled, "")

      let ws = await createServer(
        request,
        "proto",
        onClose = closeServer)

      await ws.close()
      return dumbResponse()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    proc clientClose(status: Status, reason: string): CloseResult
      {.gcsafe, raises: [Defect].} =
      try:
        check status == Status.Fulfilled
        return (Status.TooLarge, "Message too big!")
      except Exception as exc:
        raise newException(Defect, exc.msg)

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onClose = clientClose)

    discard await wsClient.recv()
    check wsClient.readyState == ReadyState.Closed

  test "Client closing":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      discard await ws.recv()
      await ws.close()
      return dumbResponse()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
    await wsClient.close()

  test "Client closing with status":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async, gcsafe.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      proc closeServer(status: Status, reason: string): CloseResult
        {.gcsafe, raises: [Defect].} =
        try:
          check status == Status.Fulfilled
          return (Status.TooLarge, "Message too big!")
        except Exception as exc:
          raise newException(Defect, exc.msg)

      let ws = await createServer(
        request,
        "proto",
        onClose = closeServer)
      discard await ws.recv()
      await ws.close()
      return dumbResponse()

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    proc clientClose(status: Status, reason: string): CloseResult
      {.gcsafe, raises: [Defect].} =
      try:
        check status == Status.TooLarge
        check reason == "Message too big!"
        return (Status.Fulfilled, "")
      except Exception as exc:
        raise newException(Defect, exc.msg)

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onClose = clientClose)

    await wsClient.close()
    check wsClient.readyState == ReadyState.Closed
