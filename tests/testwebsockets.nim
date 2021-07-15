## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[strutils, random]
import pkg/[
  httputils,
  chronos,
  chronicles,
  stew/byteutils]

import ../websock/websock

import ./asynctest
import ./helpers

let
  address* = initTAddress("127.0.0.1:8888")

var
  server: HttpServer

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

    expect WSFailedUpgradeError:
      discard await connectClient()

  test "Test for incorrect scheme":
    let uri = "wx://127.0.0.1:8888/ws"
    expect WSWrongUriSchemeError:
      discard await WebSocket.connect(
        parseUri(uri),
        protocols = @["proto"])

suite "Test transmission":
  teardown:
    server.stop()
    await server.closeWait()

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

    let session = await connectClient()
    await session.send(testString)
    await session.close()

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

    let session = await connectClient()
    var clientRes = await session.recv()
    check string.fromBytes(clientRes) == testString
    await waitForClose(session)

suite "Test ping-pong":
  teardown:
    server.stop()
    await server.closeWait()

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

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await session.ping()
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

  test "Test ping payload message length":
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

    let str = rndStr(126)
    let session = await connectClient()
    await session.ping(str.toBytes())
    await session.close()

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
      let frame1 = await ws.readFrame(@[])
      check not isNil(frame1)
      var data1 = newSeq[byte](frame1.remainder().int)
      let read1 = await ws.stream.reader.readOnce(addr data1[0], data1.len)
      check read1 == 5

      let frame2 = await ws.readFrame(@[])
      check not isNil(frame2)
      var data2 = newSeq[byte](frame2.remainder().int)
      let read2 = await ws.stream.reader.readOnce(addr data2[0], data2.len)
      check read2 == 5

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

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

    let session = await connectClient()

    expect WSMaxMessageSizeError:
      discard await session.recv(5)
    await waitForClose(session)

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

    let session = await connectClient()
    await waitForClose(session)
    check session.readyState == ReadyState.Closed

  test "Server closing with status":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      proc closeServer(status: StatusCodes, reason: string): CloseResult{.gcsafe,
          raises: [Defect].} =
        try:
          check status == StatusTooLarge
          check reason == "Message too big!"
        except Exception as exc:
          raise newException(Defect, exc.msg)

        return (StatusFulfilled, "")

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

    proc clientClose(status: StatusCodes, reason: string): CloseResult {.gcsafe,
      raises: [Defect].} =
      try:
        check status == StatusFulfilled
        return (StatusTooLarge, "Message too big!")
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

    let session = await connectClient()
    await session.close()

  test "Client closing with status":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      proc closeServer(status: StatusCodes, reason: string): CloseResult{.gcsafe,
          raises: [Defect].} =
        try:
          check status == StatusFulfilled
          return (StatusTooLarge, "Message too big!")
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

    proc clientClose(status: StatusCodes, reason: string): CloseResult {.gcsafe,
      raises: [Defect].} =
      try:
        check status == StatusTooLarge
        check reason == "Message too big!"
        return (StatusFulfilled, "")
      except Exception as exc:
        raise newException(Defect, exc.msg)

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onClose = clientClose)

    await session.close()
    check session.readyState == ReadyState.Closed

  test "Mutual closing":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      await ws.close()

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await connectClient()
    await session.close()
    await waitForClose(session)
    check session.readyState == ReadyState.Closed

  test "Server closing with valid close code 3999":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)

      await ws.close(code = StatusCodes(StatusLibsCodes.high))

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    proc closeClient(status: StatusCodes, reason: string): CloseResult
      {.gcsafe, raises: [Defect].} =
      try:
        check status == StatusCodes(StatusLibsCodes.high)
        return (StatusCodes(StatusLibsCodes.high), "Reserved StatusCodes")
      except Exception as exc:
        raise newException(Defect, exc.msg)

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onClose = closeClient)

    await waitForClose(session)

  test "Client closing with valid close code 3999":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      proc closeServer(status: StatusCodes, reason: string): CloseResult{.gcsafe,
          raises: [Defect].} =
        try:
          check status == StatusCodes(3999)
          return (StatusCodes(3999), "Reserved StatusCodes")
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

    let session = await connectClient()
    await session.close(code = StatusCodes(3999))

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

    let session = await connectClient()

    # Close with payload of length 2
    await session.close(reason = "HH")

suite "Test Payload":
  teardown:
    server.stop()
    await server.closeWait()

  test "Test payload of length 0":
    let emptyStr = ""
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      let servRes = await ws.recv()

      check:
        servRes.len == 0
        string.fromBytes(servRes) == emptyStr

      await ws.send(emptyStr)
      await ws.waitForClose()

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await connectClient()
    await session.send(emptyStr)
    let clientRes = await session.recv()

    check:
      clientRes.len == 0
      string.fromBytes(clientRes) == emptyStr

    await session.close()

  test "Test multiple payloads of length 0":
    let emptyStr = ""
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      for _ in 0..<3:
        let servRes = await ws.recv()

        check:
          servRes.len == 0
          string.fromBytes(servRes) == emptyStr

      for i in 0..3:
        await ws.send(emptyStr)

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await connectClient()

    for i in 0..3:
      await session.send(emptyStr)

    for _ in 0..<3:
      let clientRes = await session.recv()

      check:
        clientRes.len == 0
        string.fromBytes(clientRes) == emptyStr

    await session.close()

  test "Send two fragments":
    var ping, pong = false
    let testString = "1234567890"
    let msg = toBytes(testString)
    let maxFrameSize = 5

    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let server = WSServer.new(protos = ["proto"])

      let ws = await server.handleRequest(request)
      let respData = await ws.recv()

      check:
        string.fromBytes(respData) == testString

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      frameSize = maxFrameSize)

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

  test "Send two fragments with a ping with payload in-between":
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
      check:
        string.fromBytes(respData)   == testString

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

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

  test "Send text message with multiple frames":
    const FrameSize = 3000
    let testData = rndStr(FrameSize * 3)
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      let res = await ws.recv()

      check ws.binary == false
      await ws.send(res, Opcode.Text)
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let ws = await connectClient(
      address = address,
      frameSize = FrameSize
    )

    await ws.send(testData)
    let echoed = await ws.recv()
    await ws.close()

    check:
      string.fromBytes(echoed) == testData
      ws.binary == false

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

    let session = await connectClient()

    for i in 0..3:
      await session.send(emptyData, Opcode.Binary)
    await session.close()

  test "Send binary data with small text payload":
    let testData = rndBin(10)
    trace "testData", testData = testData
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

    let session = await connectClient(
      address = initTAddress("127.0.0.1:8888"),
      onPong = proc(data: openArray[byte]) =
        pong = true
    )

    await session.send(testData, Opcode.Binary)
    await session.close()

  test "Send binary message with multiple frames":
    const FrameSize = 3000
    let testData = rndBin(FrameSize * 3)
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      let res = await ws.recv()

      check:
        ws.binary == true
        res == testData

      await ws.send(res, Opcode.Binary)
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let ws = await connectClient(
      address = address,
      frameSize = FrameSize
    )

    await ws.send(testData, Opcode.Binary)
    let echoed = await ws.recv()

    check:
      echoed == testData

    await ws.close()

    check:
      echoed == testData
      ws.binary == true
