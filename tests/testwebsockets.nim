import std/strutils,httputils

import pkg/[asynctest, 
            chronos,
            chronicles,
            chronos/apps/http/httpserver, 
            stew/byteutils,
            eth/keys]

include ../src/[ws,stream,utils]

var server: HttpServerRef
let address = initTAddress("127.0.0.1:8888")

proc rndStr*(size: int): string =
  for _ in .. size:
    add(result, char(rand(int('A') .. int('z'))))

suite "Test handshake":
  teardown:
    await server.closeWait()
    
  test "Test for incorrect protocol":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      expect WSProtoMismatchError:
        var ws = await createServer(request, "proto")
        check ws.readyState == ReadyState.Closed

    let res = HttpServerRef.new(
    address, cb)
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
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      expect WSVersionError:
        var ws = await createServer(request, "proto")
        check ws.readyState == ReadyState.Closed

    let res = HttpServerRef.new(
      address, cb)
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
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      check request.headers.getString("Connection").toUpperAscii() == "Upgrade".toUpperAscii()
      check request.headers.getString("Upgrade").toUpperAscii() == "websocket".toUpperAscii()
      check request.headers.getString("Cache-Control").toUpperAscii() == "no-cache".toUpperAscii()
      check request.headers.getString("Sec-WebSocket-Version") == $WSDefaultVersion

      check request.headers.contains("Sec-WebSocket-Key")

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    expect WSFailedUpgradeError:
      discard await WebSocket.connect(
        "127.0.0.1",
        Port(8888),
        path = "/ws",
        protocols = @["proto"])

suite "Test transmission":
  teardown:
    await server.closeWait()
  test "Send text message message with payload of length 65535":
    let testString = rndStr(65535)
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      let servRes = await ws.recv()

      check string.fromBytes(servRes) == testString

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
    await wsClient.send(testString)
    await wsClient.close()
    
  test "Server - test reading simple frame":
    let testString = "Hello!"
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      let servRes = await ws.recv()

      check string.fromBytes(servRes) == testString
      await ws.stream.closeWait()

    let res = HttpServerRef.new(
      address, cb)
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
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      await ws.send(testString)
      await ws.stream.closeWait()
    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    var clientRes = await wsClient.recv()
    check string.fromBytes(clientRes) == testString

suite "Test ping-pong":
  teardown:
    await server.closeWait() 
  test "Send text Message fragmented into 2 fragments, one ping with payload in-between":
    var ping, pong = false
    let testString = "1234567890"
    let msg = toBytes(testString)
    let maxFrameSize = 5
    var maskKey = genMaskKey(newRng())
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(
        request,
        "proto",
        onPing = proc() =
          ping = true
        )

      let respData = await ws.recv()
      check string.fromBytes(respData) == testString
    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      frameSize = maxFrameSize,
      onPong = proc() =
        pong = true
      )

    let encframe = encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: true,
      data: msg[0..4],
      maskKey: maskKey))

    await wsClient.stream.writer.write(encframe)
    await wsClient.ping()
    let encframe1 = encodeFrame(Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Cont,
      mask: true,
      data: msg[5..9],
      maskKey: maskKey))  
      
    await wsClient.stream.writer.write(encframe1)
    await wsClient.close()
    check:
      ping
      pong

  test "Server - test ping-pong control messages":
    var ping, pong = false
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      check r.isOk()
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

    let res = HttpServerRef.new(
      address, cb)
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
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(
        request,
        "proto",
        onPing = proc() =
          ping = true
        )

      discard await ws.recv()
    let res = HttpServerRef.new(
      address, cb)
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
    var done = newFuture[void]()
    proc cb(r: RequestFence): Future[HttpResponseRef]{.async.} =
      check r.isOk()
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

      await ws.stream.closeWait()
      done.complete()
    
    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      frameSize = 5)

    await wsClient.send(testString)
    await done

  test "should fail to read past max message size":
    let testString = "1234567890"
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async, gcsafe.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      await ws.send(testString)
      await ws.stream.closeWait()

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    expect WSMaxMessageSizeError:
      discard await wsClient.recv(5)

suite "Test Closing":
  teardown:
    await server.closeWait()

  test "Server closing":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      await ws.close()
    let res = HttpServerRef.new(
      address, cb)
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
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      proc closeServer(status: Status, reason: string): CloseResult {.gcsafe.} =
        check status == Status.TooLarge
        check reason == "Message too big!"

        return (Status.Fulfilled, "")

      let ws = await createServer(
        request,
        "proto",
        onClose = closeServer)

      await ws.close()

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    proc clientClose(status: Status, reason: string): CloseResult {.gcsafe.} =
      check status == Status.Fulfilled
      return (Status.TooLarge, "Message too big!")

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onClose = clientClose)

    discard await wsClient.recv()
    check wsClient.readyState == ReadyState.Closed

  test "Server closing with Payload of length 1":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      # Close with payload of length 1
      await ws.close(reason="H")

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
    discard await wsClient.recv()  

  test "Server closing with Payload of length 2":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      # Close with payload of length 2
      await ws.close(reason="HH")  
      
    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
    discard await wsClient.recv()

  test "Client closing":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      discard await ws.recv()
      
    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
    await wsClient.close() 

  test "Client closing with Payload of length 1":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      discard await ws.recv()
      
    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
    # Close with payload of length 1
    await wsClient.close(reason="H")  

  test "Client closing with Payload of length 2":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request, "proto")
      discard await ws.recv()
      
    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
       # Close with payload of length 2
    await wsClient.close(reason="HH")  

  test "Client closing with status":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async, gcsafe.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      proc closeServer(status: Status, reason: string): CloseResult {.gcsafe.} =
        check status == Status.Fulfilled
        return (Status.TooLarge, "Message too big!")

      let ws = await createServer(
        request,
        "proto",
        onClose = closeServer)
      discard await ws.recv()

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    proc clientClose(status: Status, reason: string): CloseResult {.gcsafe.} =
      check status == Status.TooLarge
      check reason == "Message too big!"
      return (Status.Fulfilled, "")

    let wsClient = await WebSocket.connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onClose = clientClose)

    await wsClient.close()
    check wsClient.readyState == ReadyState.Closed

  test "Client closing with valid close code 3999":
    proc cb(r: RequestFence): Future[HttpResponseRef] {.async, gcsafe.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"

      let ws = await createServer(
        request,
        "proto")
      discard await ws.recv()

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])
    await wsClient.close()

suite "Test Payload":
  teardown:
    await server.closeWait()

  test "Test payload message length":
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(
        request,
        "proto")

      expect WSPayloadTooLarge:
        discard waitFor ws.recv()
      await ws.stream.closeWait()

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let str = rndStr(126)
    let wsClient = await wsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    await wsClient.send(toBytes(str), Opcode.Ping) 
    
  test "Test empty payload message length":
    let emptyStr = ""
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request,"proto")
      let servRes = await ws.recv()
      check string.fromBytes(servRes) == emptyStr
      await ws.stream.closeWait()

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
      "127.0.0.1",
    Port(8888),
      path = "/ws",
      protocols = @["proto"])

    await wsClient.send(emptyStr)

  test "Test multiple empty payload message length":
    let emptyStr = ""
    proc cb(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(request,"proto")
      var servRes: seq[byte]
      servRes = await ws.recv()
      check string.fromBytes(servRes) == emptyStr

    let res = HttpServerRef.new(
      address, cb)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
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
    proc process(r: RequestFence): Future[HttpResponseRef]  {.async.} =
      check r.isOk()
      let request = r.get()
      check request.uri.path == "/ws"
      let ws = await createServer(
        request,
        "proto",
        onPing = proc() =
          ping = true
        )

      discard await ws.recv()

    let res = HttpServerRef.new(
      address, process)
    server = res.get()
    server.start()

    let wsClient = await wsConnect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onPong = proc() =
        pong = true
      )

    await wsClient.send(testData, Opcode.Ping)
    await wsClient.close()
    check:
      ping
      pong
