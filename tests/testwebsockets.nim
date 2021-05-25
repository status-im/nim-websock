import std/[strutils, random], httputils

import pkg/[asynctest,
        chronos,
        chronos/apps/http/httpserver,
        chronicles,
        stew/byteutils]

import ../ws/[ws, stream, utils, frame, errors]

var server: HttpServerRef
let address = initTAddress("127.0.0.1:8888")

proc rndStr*(size: int): string =
  for _ in .. size:
    add(result, char(rand(int('A') .. int('z'))))

proc rndBin*(size: int): seq[byte] =
   for _ in .. size:
      add(result, byte(rand(0 .. 255)))

proc waitForClose(ws: WebSocket) {.async.} =
  try:
    while ws.readystate != ReadyState.Closed:
      discard await ws.recv()
  except CatchableError:
    debug "Closing websocket"

suite "Test handshake":
  teardown:
    await server.stop()
    await server.closeWait()

  test "Test for incorrect protocol":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      expect WSProtoMismatchError:
        discard await WebSocket.createServer(request, "proto")

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
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      expect WSVersionError:
        discard await WebSocket.createServer(request, "proto")

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
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      check request.headers.getString("Connection").toUpperAscii() ==
        "Upgrade".toUpperAscii()
      check request.headers.getString("Upgrade").toUpperAscii() ==
        "websocket".toUpperAscii()
      check request.headers.getString("Cache-Control").toUpperAscii() ==
        "no-cache".toUpperAscii()
      check request.headers.getString("Sec-WebSocket-Version") == $WSDefaultVersion

      check request.headers.contains("Sec-WebSocket-Key")
      discard await request.respond(Http200, "Connection established")

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
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"

      expect WSProtoMismatchError:
        var ws = await WebSocket.createServer(request, "proto")
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

  test "AsyncStream leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

suite "Test transmission":
  teardown:
    await server.closeWait()

  test "Send text message message with payload of length 65535":
    let testString = rndStr(65535)
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(request, "proto")
      let servRes = await ws.recv()
      check string.fromBytes(servRes) == testString

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

  test "Server - test reading simple frame":
    let testString = "Hello!"
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(request, "proto")
      let servRes = await ws.recv()
      check string.fromBytes(servRes) == testString
      await waitForClose(ws)

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
    when defined(windows):
      # TODO: fix this err on Windows
      # Unhandled exception: Stream is already closed! [AsyncStreamIncorrectDefect]
      skip()
    else:
      let testString = "Hello!"
      proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
        if r.isErr():
          return dumbResponse()

        let request = r.get()
        check request.uri.path == "/ws"
        let ws = await WebSocket.createServer(request, "proto")
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
      check string.fromBytes(clientRes) == testString
      await waitForClose(wsClient)

  test "AsyncStream leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

suite "Test ping-pong":
  teardown:
    await server.closeWait()
  test "Send text Message fragmented into 2 fragments, one ping with payload in-between":
    var ping, pong = false
    let testString = "1234567890"
    let msg = toBytes(testString)
    let maxFrameSize = 5

    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(
        request,
        "proto",
        onPing = proc(data: openArray[byte]) =
          ping = true
      )

      let respData = await ws.recv()
      check string.fromBytes(respData) == testString
      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      frameSize = maxFrameSize,
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    let maskKey = genMaskKey(newRng())
    await wsClient.stream.writer.write(
      Frame(
        fin: false,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: Opcode.Text,
        mask: true,
        data: msg[0..4],
        maskKey: maskKey)
        .encode())

    await wsClient.ping()

    await wsClient.stream.writer.write(
      Frame(
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: Opcode.Cont,
        mask: true,
        data: msg[5..9],
        maskKey: maskKey)
        .encode())

    await wsClient.close()
    check:
      ping
      pong

  test "Server - test ping-pong control messages":
    when defined(windows):
      # TODO: fix this err on Windows
      # Unhandled exception: Stream is already closed! [AsyncStreamIncorrectDefect]
      skip()
    else:
      var ping, pong = false
      proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
        if r.isErr():
            return dumbResponse()

        let request = r.get()
        check request.uri.path == "/ws"
        let ws = await WebSocket.createServer(
          request,
          "proto",
          onPong = proc(data: openArray[byte]) =
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
        onPing = proc(data: openArray[byte]) =
          ping = true
      )

      await waitForClose(wsClient)
      check:
        ping
        pong

  test "Client - test ping-pong control messages":
    var ping, pong = false
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(
        request,
        "proto",
        onPing = proc(data: openArray[byte]) =
          ping = true
      )
      await waitForClose(ws)
      check:
        ping
        pong

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await wsClient.ping()
    await wsClient.close()

  test "AsyncStream leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

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

      let ws = await WebSocket.createServer(request, "proto")
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

      await waitForClose(ws)

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
    when defined(windows):
      # TODO: fix this err on Windows
      # Unhandled exception: Stream is already closed! [AsyncStreamIncorrectDefect]
      skip()
    else:
      let testString = "1234567890"
      proc cb(r: RequestFence): Future[HttpResponseRef] {.async, gcsafe.} =
        if r.isErr():
            return dumbResponse()

        let request = r.get()
        check request.uri.path == "/ws"
        let ws = await WebSocket.createServer(request, "proto")
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

      expect WSMaxMessageSizeError:
        discard await wsClient.recv(5)
      await waitForClose(wsClient)

  test "AsyncStream leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

suite "Test Closing":
  teardown:
    await server.closeWait()

  test "Server closing":
    when defined(windows):
      # TODO: fix this err on Windows
      # Unhandled exception: Stream is already closed! [AsyncStreamIncorrectDefect]
      skip()
    else:
      proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
        if r.isErr():
            return dumbResponse()

        let request = r.get()
        check request.uri.path == "/ws"
        let ws = await WebSocket.createServer(request, "proto")
        await ws.close()

      let res = HttpServerRef.new(address, cb)
      server = res.get()
      server.start()

      let wsClient = await WebSocket.connect(
        "127.0.0.1",
        Port(8888),
        path = "/ws",
        protocols = @["proto"])

      await waitForClose(wsClient)
      check wsClient.readyState == ReadyState.Closed

  test "Server closing with status":
    when defined(windows):
      # TODO: fix this err on Windows
      # Unhandled exception: Stream is already closed! [AsyncStreamIncorrectDefect]
      skip()
    else:
      proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
        if r.isErr():
          return dumbResponse()

        let request = r.get()
        check request.uri.path == "/ws"

        proc closeServer(status: Status, reason: string): CloseResult{.gcsafe,
            raises: [Defect].} =
          try:
            check status == Status.TooLarge
            check reason == "Message too big!"
          except Exception as exc:
            raise newException(Defect, exc.msg)

          return (Status.Fulfilled, "")

        let ws = await WebSocket.createServer(
          request,
          "proto",
          onClose = closeServer)

        await ws.close()

      let res = HttpServerRef.new(address, cb)
      server = res.get()
      server.start()

      proc clientClose(status: Status, reason: string): CloseResult {.gcsafe,
        raises: [Defect].} =
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

      await waitForClose(wsClient)
      check wsClient.readyState == ReadyState.Closed

  test "Client closing":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()

      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(request, "proto")
      await waitForClose(ws)

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
      proc closeServer(status: Status, reason: string): CloseResult{.gcsafe,
          raises: [Defect].} =
        try:
          check status == Status.Fulfilled
          return (Status.TooLarge, "Message too big!")
        except Exception as exc:
          raise newException(Defect, exc.msg)

      let ws = await WebSocket.createServer(
        request,
        "proto",
        onClose = closeServer)
      await waitForClose(ws)

    let res = HttpServerRef.new(address, cb)
    server = res.get()
    server.start()

    proc clientClose(status: Status, reason: string): CloseResult {.gcsafe,
      raises: [Defect].} =
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

  test "Server closing with valid close code 3999":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async, gcsafe.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(
        request,
        "proto")

      await ws.close(code = Status.ReservedCode)

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    proc closeClient(status: Status, reason: string): CloseResult{.gcsafe,
        raises: [Defect].} =
      try:
        check status == Status.ReservedCode
        return (Status.ReservedCode, "Reserved Status")
      except Exception as exc:
        raise newException(Defect, exc.msg)

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onClose = closeClient)

    await waitForClose(wsClient)

  test "Client closing with valid close code 3999":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async, gcsafe.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"

      proc closeServer(status: Status, reason: string): CloseResult{.gcsafe,
          raises: [Defect].} =
        try:
          check status == Status.ReservedCode
          return (Status.ReservedCode, "Reserved Status")
        except Exception as exc:
          raise newException(Defect, exc.msg)

      let ws = await WebSocket.createServer(
        request,
        "proto",
        onClose = closeServer)

      await waitForClose(ws)
      return dumbResponse()

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
    await wsClient.close(code = Status.ReservedCode)

  test "Server closing with Payload of length 2":
    when defined(windows):
      # TODO: fix this err on Windows
      # Unhandled exception: Stream is already closed! [AsyncStreamIncorrectDefect]
      skip()
    else:
      proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
        if r.isErr():
            return dumbResponse()
        let request = r.get()
        check request.uri.path == "/ws"
        let ws = await WebSocket.createServer(request, "proto")
        # Close with payload of length 2
        await ws.close(reason = "HH")

      let res = HttpServerRef.new(
      address, cb)
      server = res.get()
      server.start()

      let wsClient = await WebSocket.connect(
        "127.0.0.1",
        Port(8888),
        path = "/ws",
        protocols = @["proto"])
      await waitForClose(wsClient)

  test "Client closing with Payload of length 2":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(request, "proto")
      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
      # Close with payload of length 2
    await wsClient.close(reason = "HH")

  test "AsyncStream leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

suite "Test Payload":
  teardown:
    await server.closeWait()

  test "Test payload message length":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(
        request,
        "proto")

      expect WSPayloadTooLarge:
        discard await ws.recv()

      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let str = rndStr(126)
    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    await wsClient.ping(str.toBytes())
    await wsClient.close()

  test "Test single empty payload":
    let emptyStr = ""
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(request, "proto")
      let servRes = await ws.recv()
      check string.fromBytes(servRes) == emptyStr
      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    await wsClient.send(emptyStr)
    await wsClient.close()

  test "Test multiple empty payload":
    let emptyStr = ""
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(request, "proto")
      let servRes = await ws.recv()
      check string.fromBytes(servRes) == emptyStr
      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    for i in 0..3:
      await wsClient.send(emptyStr)
    await wsClient.close()

  test "Send ping with small text payload":
    let testData = toBytes("Hello, world!")
    var ping, pong = false
    proc process(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(
        request,
        "proto",
        onPing = proc(data: openArray[byte]) =
          ping = data == testData
      )

      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, process)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await wsClient.ping(testData)
    await wsClient.close()
    check:
      ping
      pong

  test "AsyncStream leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

suite "Test Binary message with Payload":
  teardown:
    await server.closeWait()

  test "Test binary message with single empty payload message":
    let emptyData = newSeq[byte](0)
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(request, "proto")
      let servRes = await ws.recv()

      check:
        servRes == emptyData
        ws.binary == true

      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    await wsClient.send(emptyData, Opcode.Binary)
    await wsClient.close()

  test "Test binary message with multiple empty payload":
    let emptyData = newSeq[byte](0)
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(request, "proto")
      let servRes = await ws.recv()

      check:
        servRes == emptyData
        ws.binary == true

      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    for i in 0..3:
      await wsClient.send(emptyData, Opcode.Binary)
    await wsClient.close()

  test "Send binary data with small text payload":
    let testData = rndBin(10)
    debug "testData", testData = testData
    var ping, pong = false
    proc process(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(
        request,
        "proto",
        onPing = proc(data: openArray[byte]) =
          ping = true
      )

      let res = await ws.recv()
      check:
        res == testData
        ws.binary == true

      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, process)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await wsClient.send(testData, Opcode.Binary)
    await wsClient.close()

  test "Send binary message message with payload of length 125":
    let testData = rndBin(125)
    var ping, pong = false
    proc process(r: RequestFence): Future[HttpResponseRef] {.async.} =
      if r.isErr():
        return dumbResponse()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await WebSocket.createServer(
        request,
        "proto",
        onPing = proc(data: openArray[byte]) =
          ping = true
      )

      let res = await ws.recv()
      check:
        res == testData
        ws.binary == true

      await waitForClose(ws)

    let res = HttpServerRef.new(
      address, process)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await wsClient.send(testData, Opcode.Binary)
    await wsClient.close()

  test "AsyncStream leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false
