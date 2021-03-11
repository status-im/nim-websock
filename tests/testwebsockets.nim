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
