import std/strutils
import pkg/[asynctest, chronos, httputils]
import pkg/stew/byteutils

import ../src/http,
       ../src/ws,
       ../src/random

import ./helpers

var httpServer: HttpServer

suite "Test handshake":
  teardown:
    httpServer.stop()
    await httpServer.closeWait()

  test "Test for incorrect protocol":
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      expect WSProtoMismatchError:
        var ws = await createServer(header, transp, "proto")
        check ws.readyState == ReadyState.Closed

      check await transp.sendHTTPResponse(
        HttpVersion11,
        Http200,
        "Connection established")

      await transp.closeWait()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    expect WSFailedUpgradeError:
      discard await connect(
        "127.0.0.1",
        Port(8888),
        path = "/ws",
        protocols = @["wrongproto"])

  test "Test for incorrect version":
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      expect WSVersionError:
        var ws = await createServer(header, transp, "proto")
        check ws.readyState == ReadyState.Closed

      check await transp.sendHTTPResponse(
        HttpVersion11,
        Http200,
        "Connection established")

      await transp.closeWait()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    expect WSFailedUpgradeError:
      discard await connect(
        "127.0.0.1",
        Port(8888),
        path = "/ws",
        protocols = @["wrongproto"],
        version = 14)

  test "Test for client headers":
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      check header["Connection"].toUpperAscii() == "Upgrade".toUpperAscii()
      check header["Upgrade"].toUpperAscii() == "websocket".toUpperAscii()
      check header["Cache-Control"].toUpperAscii() == "no-cache".toUpperAscii()
      check header["Sec-WebSocket-Version"] == $WSDefaultVersion

      check "Sec-WebSocket-Key" in header

      await transp.closeWait()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    expect ValueError:
      discard await connect(
        "127.0.0.1",
        Port(8888),
        path = "/ws",
        protocols = @["proto"])

suite "Test transmission":
  teardown:
    httpServer.stop()
    await httpServer.closeWait()

  test "Server - test reading simple frame":
    let testString = "Hello!"
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      let ws = await createServer(header, transp, "proto")
      let res = await ws.recv()

      check string.fromBytes(res) == testString
      await transp.closeWait()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    let ws = await connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    await ws.send(testString)

  test "Client - test ping-pong control messages":
    var ping = false
    var pong = false
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      let ws = await createServer(
        header,
        transp,
        "proto",
        onPong = proc(ws: WebSocket) =
          pong = true
        )

      await ws.ping()
      await ws.close()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    let ws = await connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onPing = proc(ws: WebSocket) =
        ping = true
      )

    discard await ws.recv()

    check:
      ping
      pong

  test "Client - test reading simple frame":
    let testString = "Hello!"
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      let ws = await createServer(header, transp, "proto")
      await ws.send(testString)
      await transp.closeWait()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    let ws = await connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    let res = await ws.recv()
    check string.fromBytes(res) == testString

  test "Client - test ping-pong control messages":
    var ping = false
    var pong = false
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      let ws = await createServer(
        header,
        transp,
        "proto",
        onPing = proc(ws: WebSocket) =
          ping = true
        )

      discard await ws.recv()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    let ws = await connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      onPong = proc(ws: WebSocket) =
        pong = true
      )

    await ws.ping()
    await ws.close()

    check:
      ping
      pong

suite "Test framing":
  teardown:
    httpServer.stop()
    await httpServer.closeWait()

  test "should split message into frames":
    let testString = "1234567890"
    var done = newFuture[void]()
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      let ws = await createServer(header, transp, "proto")

      let frame1 = await ws.readFrame()
      check not isNil(frame1)
      var data1 = newSeq[byte](frame1.remainder().int)
      let read1 = await ws.tcpSocket.readOnce(addr data1[0], data1.len)
      check read1 == 5

      let frame2 = await ws.readFrame()
      check not isNil(frame2)
      var data2 = newSeq[byte](frame2.remainder().int)
      let read2 = await ws.tcpSocket.readOnce(addr data2[0], data2.len)
      check read2 == 5

      await transp.closeWait()
      done.complete()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    let ws = await connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"],
      frameSize = 5)

    await ws.send(testString)
    await done

  test "should fail to read past max message size":
    let testString = "1234567890"
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      let ws = await createServer(header, transp, "proto")
      await ws.send(testString)
      await transp.closeWait()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    let ws = await connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    expect WSMaxMessageSizeError:
      discard await ws.recv(5)

suite "Test Closing":
  teardown:
    httpServer.stop()
    await httpServer.closeWait()

  test "Server closing":
    let testString = "Hello!"
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      let ws = await createServer(header, transp, "proto")
      await ws.close()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    let ws = await connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    await ws.send(testString)
    discard await ws.recv()
    check ws.readyState == ReadyState.Closed

  test "Client - test reading simple frame":
    let testString = "Hello!"
    proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
      check header.uri() == "/ws"

      let ws = await createServer(header, transp, "proto")
      discard await ws.recv()

    httpServer = newHttpServer("127.0.0.1:8888", cb)
    httpServer.start()

    let ws = await connect(
      "127.0.0.1",
      Port(8888),
      path = "/ws",
      protocols = @["proto"])

    await ws.close()
