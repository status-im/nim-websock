import std/[strutils, random]
import pkg/[
  httputils,
  chronos,
  chronicles,
  stew/byteutils]

import ./asynctest
import ../ws/ws
import ./keys

var server: HttpServer

let
  address = initTAddress("127.0.0.1:8888")
  socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
  clientFlags = {NoVerifyHost, NoVerifyServerName}
  secureKey = TLSPrivateKey.init(SecureKey)
  secureCert = TLSCertificate.init(SecureCert)

const WSPath = when defined secure: "/wss" else: "/ws"

proc rndStr*(size: int): string =
  for _ in .. size:
    add(result, char(rand(int('A') .. int('z'))))

proc rndBin*(size: int): seq[byte] =
   for _ in .. size:
      add(result, byte(rand(0 .. 255)))

proc waitForClose(ws: WSSession) {.async.} =
  try:
    while ws.readystate != ReadyState.Closed:
      discard await ws.recv()
  except CatchableError:
    debug "Closing websocket"

proc createServer(
  address = initTAddress("127.0.0.1:8888"),
  tlsPrivateKey = secureKey,
  tlsCertificate = secureCert,
  handler: HttpAsyncCallback = nil,
  flags: set[ServerFlags] = socketFlags,
  tlsFlags: set[TLSFlags] = {},
  tlsMinVersion = TLSVersion.TLS12,
  tlsMaxVersion = TLSVersion.TLS12): HttpServer =
  when defined secure:
    TlsHttpServer.create(
      address = address,
      tlsPrivateKey = tlsPrivateKey,
      tlsCertificate = tlsCertificate,
      handler = handler,
      flags = flags,
      tlsFlags = tlsFlags,
      tlsMinVersion = tlsMinVersion,
      tlsMaxVersion = tlsMaxVersion)
  else:
    HttpServer.create(
      address = address,
      handler = handler,
      flags = flags)

proc connectClient*(
  address = initTAddress("127.0.0.1:8888"),
  path = WSPath,
  protocols: seq[string] = @["proto"],
  flags: set[TLSFlags] = clientFlags,
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  rng: Rng = nil): Future[WSSession] {.async.} =
  let secure = when defined secure: true else: false
  return await WebSocket.connect(
    address = address,
    flags = flags,
    path = path,
    secure = secure,
    protocols = protocols,
    version = version,
    frameSize = frameSize,
    onPing = onPing,
    onPong = onPong,
    onClose = onClose,
    rng = rng)

suite "Test handshake":
  teardown:
    server.stop()
    await server.closeWait()

  test "Should not select incorrect protocol":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let
        server = WSServer.new(protos = ["proto"])
        ws = await server.handleRequest(request)
      check ws.proto == ""

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      protocols = @["wrongproto"])

    check session.proto == ""
    await session.stream.closeWait()

  test "Test for incorrect version":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["ws"])

      expect WSVersionError:
        discard await server.handleRequest(request)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    expect WSFailedUpgradeError:
      let session = await connectClient(
        address = initTAddress("127.0.0.1:8888"),
        version = 14)

  test "Test for client headers":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      check request.headers.getString("Connection").toUpperAscii() ==
        "Upgrade".toUpperAscii()
      check request.headers.getString("Upgrade").toUpperAscii() ==
        "websocket".toUpperAscii()
      check request.headers.getString("Cache-Control").toUpperAscii() ==
        "no-cache".toUpperAscii()
      check request.headers.getString("Sec-WebSocket-Version") == $WSDefaultVersion
      check request.headers.contains("Sec-WebSocket-Key")

      await request.sendError(Http500)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    expect WSFailedUpgradeError:
      discard await connectClient()

  test "Test for incorrect scheme":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      expect WSProtoMismatchError:
        let ws = await server.handleRequest(request)
        check ws.readyState == ReadyState.Closed

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let uri = "wx://127.0.0.1:8888/ws"
    expect WSWrongUriSchemeError:
      discard await WebSocket.connect(
        parseUri(uri),
        protocols = @["proto"])

  # test "AsyncStream leaks test":
  #   check:
  #     getTracker("async.stream.reader").isLeaked() == false
  #     getTracker("async.stream.writer").isLeaked() == false
  #     getTracker("stream.server").isLeaked() == false
  #     getTracker("stream.transport").isLeaked() == false

suite "Test transmission":
  teardown:
    server.stop()
    await server.closeWait()

  test "Send text message message with payload of length 65535":
    let testString = rndStr(65535)
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      let servRes = await ws.recv()
      check string.fromBytes(servRes) == testString
      await ws.waitForClose()

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()
    await session.send(testString)
    await session.close()

  test "Server - test reading simple frame":
    let testString = "Hello!"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      let servRes = await ws.recv()

      check string.fromBytes(servRes) == testString
      await ws.waitForClose()

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()
    await session.send(testString)
    await session.close()

  test "Client - test reading simple frame":
    let testString = "Hello!"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)

      await ws.send(testString)
      await ws.close()

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()
    var clientRes = await session.recv()
    check string.fromBytes(clientRes) == testString
    await waitForClose(session)

  # test "AsyncStream leaks test":
  #   check:
  #     getTracker("async.stream.reader").isLeaked() == false
  #     getTracker("async.stream.writer").isLeaked() == false
  #     getTracker("stream.server").isLeaked() == false
  #     getTracker("stream.transport").isLeaked() == false

suite "Test ping-pong":
  teardown:
    server.stop()
    await server.closeWait()

  test "Send text Message fragmented into 2 fragments, one ping with payload in-between":
    var ping, pong = false
    let testString = "1234567890"
    let msg = toBytes(testString)
    let maxFrameSize = 5

    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(
        protos = ["proto"],
        onPing = proc(data: openArray[byte]) =
          ping = true
        )

      let ws = await server.handleRequest(request)

      let respData = await ws.recv()
      check string.fromBytes(respData) == testString
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      frameSize = maxFrameSize,
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    let maskKey = genMaskKey(newRng())
    await session.stream.writer.write(
      (await Frame(
        fin: false,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: Opcode.Text,
        mask: true,
        data: msg[0..4],
        maskKey: maskKey)
        .encode()))

    await session.ping()

    await session.stream.writer.write(
      (await Frame(
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: Opcode.Cont,
        mask: true,
        data: msg[5..9],
        maskKey: maskKey)
        .encode()))

    await session.close()
    check:
      ping
      pong

  test "Server - test ping-pong control messages":
    var ping, pong = false
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(
        protos = ["proto"],
        onPong = proc(data: openArray[byte]) =
          pong = true
      )
      let ws = await server.handleRequest(request)

      await ws.ping()
      await ws.close()

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onPing = proc(data: openArray[byte]) =
        ping = true
    )

    await waitForClose(session)
    check:
      ping
      pong

  test "Client - test ping-pong control messages":
    var ping, pong = false
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(
        protos = ["proto"],
        onPing = proc(data: openArray[byte]) =
          ping = true
      )

      let ws = await server.handleRequest(request)
      await waitForClose(ws)
      check:
        ping
        pong

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await session.ping()
    await session.close()

#   test "AsyncStream leaks test":
#     check:
#       getTracker("async.stream.reader").isLeaked() == false
#       getTracker("async.stream.writer").isLeaked() == false
#       getTracker("stream.server").isLeaked() == false
#       getTracker("stream.transport").isLeaked() == false

suite "Test framing":
  teardown:
    server.stop()
    await server.closeWait()

  test "should split message into frames":
    let testString = "1234567890"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
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

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      frameSize = 5)

    await session.send(testString)
    await session.close()

  test "should fail to read past max message size":
    let testString = "1234567890"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      await ws.send(testString)
      await ws.close()

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()

    expect WSMaxMessageSizeError:
      discard await session.recv(5)

    await waitForClose(session)

#   test "AsyncStream leaks test":
#     check:
#       getTracker("async.stream.reader").isLeaked() == false
#       getTracker("async.stream.writer").isLeaked() == false
#       getTracker("stream.server").isLeaked() == false
#       getTracker("stream.transport").isLeaked() == false

suite "Test Closing":
  teardown:
    server.stop()
    await server.closeWait()

  test "Server closing":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      await ws.close()

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()
    await waitForClose(session)
    check session.readyState == ReadyState.Closed

  test "Server closing with status":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      proc closeServer(status: Status, reason: string): CloseResult{.gcsafe,
          raises: [Defect].} =
        try:
          check status == Status.TooLarge
          check reason == "Message too big!"
        except Exception as exc:
          raise newException(Defect, exc.msg)

        return (Status.Fulfilled, "")

      let server = WSServer.new(
        protos = ["proto"],
        onClose = closeServer
      )

      let ws = await server.handleRequest(request)
      await ws.close()

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    proc clientClose(status: Status, reason: string): CloseResult {.gcsafe,
      raises: [Defect].} =
      try:
        check status == Status.Fulfilled
        return (Status.TooLarge, "Message too big!")
      except Exception as exc:
        raise newException(Defect, exc.msg)

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onClose = clientClose)

    await waitForClose(session)
    check session.readyState == ReadyState.Closed

  test "Client closing":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()
    await session.close()

  test "Client closing with status":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      proc closeServer(status: Status, reason: string): CloseResult{.gcsafe,
          raises: [Defect].} =
        try:
          check status == Status.Fulfilled
          return (Status.TooLarge, "Message too big!")
        except Exception as exc:
          raise newException(Defect, exc.msg)

      let server = WSServer.new(
        protos = ["proto"],
        onClose = closeServer
      )

      let ws = await server.handleRequest(request)
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    proc clientClose(status: Status, reason: string): CloseResult {.gcsafe,
      raises: [Defect].} =
      try:
        check status == Status.TooLarge
        check reason == "Message too big!"
        return (Status.Fulfilled, "")
      except Exception as exc:
        raise newException(Defect, exc.msg)

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onClose = clientClose)

    await session.close()
    check session.readyState == ReadyState.Closed

  test "Server closing with valid close code 3999":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)

      await ws.close(code = Status.ReservedCode)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    proc closeClient(status: Status, reason: string): CloseResult{.gcsafe,
        raises: [Defect].} =
      try:
        check status == Status.ReservedCode
        return (Status.ReservedCode, "Reserved Status")
      except Exception as exc:
        raise newException(Defect, exc.msg)

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onClose = closeClient)

    await waitForClose(session)

  test "Client closing with valid close code 3999":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      proc closeServer(status: Status, reason: string): CloseResult{.gcsafe,
          raises: [Defect].} =
        try:
          check status == Status.ReservedCode
          return (Status.ReservedCode, "Reserved Status")
        except Exception as exc:
          raise newException(Defect, exc.msg)

      let server = WSServer.new(
        protos = ["proto"],
        onClose = closeServer
      )
      let ws = await server.handleRequest(request)

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()
    await session.close(code = Status.ReservedCode)

  test "Server closing with Payload of length 2":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)

      # Close with payload of length 2
      await ws.close(reason = "HH")

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()
    await waitForClose(session)

  test "Client closing with Payload of length 2":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()

    # Close with payload of length 2
    await session.close(reason = "HH")

#   test "AsyncStream leaks test":
#     check:
#       getTracker("async.stream.reader").isLeaked() == false
#       getTracker("async.stream.writer").isLeaked() == false
#       getTracker("stream.server").isLeaked() == false
#       getTracker("stream.transport").isLeaked() == false

suite "Test Payload":
  teardown:
    server.stop()
    await server.closeWait()

  test "Test payload message length":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)

      expect WSPayloadTooLarge:
        discard await ws.recv()

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let str = rndStr(126)
    let session = await connectClient()
    await session.ping(str.toBytes())
    await session.close()

  test "Test single empty payload":
    let emptyStr = ""
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      let servRes = await ws.recv()

      check string.fromBytes(servRes) == emptyStr
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()

    await session.send(emptyStr)
    await session.close()

  test "Test multiple empty payload":
    let emptyStr = ""
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      let servRes = await ws.recv()

      check string.fromBytes(servRes) == emptyStr
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()
    for i in 0..3:
      await session.send(emptyStr)
    await session.close()

  test "Send ping with small text payload":
    let testData = toBytes("Hello, world!")
    var ping, pong = false
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(
        protos = ["proto"],
        onPing = proc(data: openArray[byte]) =
          ping = data == testData)

      let ws = await server.handleRequest(request)
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await session.ping(testData)
    await session.close()
    check:
      ping
      pong

#   test "AsyncStream leaks test":
#     check:
#       getTracker("async.stream.reader").isLeaked() == false
#       getTracker("async.stream.writer").isLeaked() == false
#       getTracker("stream.server").isLeaked() == false
#       getTracker("stream.transport").isLeaked() == false

suite "Test Binary message with Payload":
  teardown:
    server.stop()
    await server.closeWait()

  test "Test binary message with single empty payload message":
    let emptyData = newSeq[byte](0)
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      let servRes = await ws.recv()

      check:
        servRes == emptyData
        ws.binary == true

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()
    await session.send(emptyData, Opcode.Binary)
    await session.close()

  test "Test binary message with multiple empty payload":
    let emptyData = newSeq[byte](0)
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)

      let servRes = await ws.recv()

      check:
        servRes == emptyData
        ws.binary == true

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient()

    for i in 0..3:
      await session.send(emptyData, Opcode.Binary)
    await session.close()

  test "Send binary data with small text payload":
    let testData = rndBin(10)
    debug "testData", testData = testData
    var ping, pong = false
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(
        protos = ["proto"],
        onPing = proc(data: openArray[byte]) =
          ping = true
      )
      let ws = await server.handleRequest(request)

      let res = await ws.recv()
      check:
        res == testData
        ws.binary == true

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await session.send(testData, Opcode.Binary)
    await session.close()

  test "Send binary message message with payload of length 125":
    let testData = rndBin(125)
    var ping, pong = false
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(
        protos = ["proto"],
        onPing = proc(data: openArray[byte]) =
          ping = true
      )
      let ws = await server.handleRequest(request)

      let res = await ws.recv()
      check:
        res == testData
        ws.binary == true

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})
    server.start()

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await session.send(testData, Opcode.Binary)
    await session.close()

#   test "AsyncStream leaks test":
#     check:
#       getTracker("async.stream.reader").isLeaked() == false
#       getTracker("async.stream.writer").isLeaked() == false
#       getTracker("stream.server").isLeaked() == false
#       getTracker("stream.transport").isLeaked() == false
