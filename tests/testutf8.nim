## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import
  std/[strutils],
  pkg/[
    stew/byteutils,
    asynctest/unittest2,
    chronos,
    chronicles
  ],
  ../websock/[websock, utf8dfa]

suite "UTF-8 DFA validator":
  test "single octet":
    check:
      validateUTF8("\x01")
      validateUTF8("\x32")
      validateUTF8("\x7f")
      validateUTF8("\x80") == false

  test "two octets":
    check:
      validateUTF8("\xc2\x80")
      validateUTF8("\xc4\x80")
      validateUTF8("\xdf\xbf")
      validateUTF8("\xdfu\xc0") == false
      validateUTF8("\xdf") == false

  test "three octets":
    check:
      validateUTF8("\xe0\xa0\x80")
      validateUTF8("\xe1\x80\x80")
      validateUTF8("\xef\xbf\xbf")
      validateUTF8("\xef\xbf\xc0") == false
      validateUTF8("\xef\xbf") == false

  test "four octets":
    check:
      validateUTF8("\xf0\x90\x80\x80")
      validateUTF8("\xf0\x92\x80\x80")
      validateUTF8("\xf0\x9f\xbf\xbf")
      validateUTF8("\xf0\x9f\xbf\xc0") == false
      validateUTF8("\xf0\x9f\xbf") == false

  test "overlong sequence":
    check:
      validateUTF8("\xc0\xaf") == false
      validateUTF8("\xe0\x80\xaf") == false
      validateUTF8("\xf0\x80\x80\xaf") == false
      validateUTF8("\xf8\x80\x80\x80\xaf") == false
      validateUTF8("\xfc\x80\x80\x80\x80\xaf") == false

  test "max overlong sequence":
    check:
      validateUTF8("\xc1\xbf") == false
      validateUTF8("\xe0\x9f\xbf") == false
      validateUTF8("\xf0\x8f\xbf\xbf") == false
      validateUTF8("\xf8\x87\xbf\xbf\xbf") == false
      validateUTF8("\xfc\x83\xbf\xbf\xbf\xbf") == false

  test "distinct codepoint":
    check:
      validateUTF8("foobar")
      validateUTF8("foob\xc3\xa6r")
      validateUTF8("foob\xf0\x9f\x99\x88r")

proc waitForClose(ws: WSSession) {.async.} =
  try:
    while ws.readystate != ReadyState.Closed:
      discard await ws.recvMsg()
  except CatchableError:
    trace "Closing websocket"

suite "UTF-8 validator in action":

  var server: HttpServer
  let address = initTAddress("127.0.0.1:8888")

  teardown:
    server.stop()
    await server.closeWait()

  test "valid UTF-8 sequence":
    let testData = "hello world"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == "/ws"

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)

      let res = await ws.recvMsg()
      check:
        string.fromBytes(res) == testData
        ws.binary == false

      await waitForClose(ws)

    server = HttpServer.create(
      address,
      handle,
      flags = {ReuseAddr})
    server.start()

    let session = await WebSocket.connect(
      "127.0.0.1:8888",
      path = "/ws",
      protocols = @["proto"],
    )

    await session.send(testData)
    await session.close()

  test "valid UTF-8 sequence in close reason":
    let testData = "hello world"
    let closeReason = "i want to close"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == "/ws"

      proc onClose(status: StatusCodes, reason: string):
        CloseResult {.gcsafe, raises: [Defect].} =
        try:
          check status == StatusFulfilled
          check reason == closeReason
          return (status, reason)
        except Exception as exc:
          raise newException(Defect, exc.msg)

      let server = WSServer.new(protos = ["proto"], onClose = onClose)
      let ws = await server.handleRequest(request)
      let res = await ws.recvMsg()
      await waitForClose(ws)

      check:
        string.fromBytes(res) == testData
        ws.binary == false

      await waitForClose(ws)

    server = HttpServer.create(
      address,
      handle,
      flags = {ReuseAddr})
    server.start()

    let session = await WebSocket.connect(
      "127.0.0.1:8888",
      path = "/ws",
      protocols = @["proto"],
    )

    await session.send(testData)
    await session.close(reason = closeReason)

  test "invalid UTF-8 sequence":
    let testData = "hello world\xc0\xaf"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == "/ws"

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      await ws.send(testData)
      await waitForClose(ws)

    server = HttpServer.create(
      address,
      handle,
      flags = {ReuseAddr})
    server.start()

    let session = await WebSocket.connect(
      "127.0.0.1:8888",
      path = "/ws",
      protocols = @["proto"]
    )

    expect WSInvalidUTF8:
      let data = await session.recvMsg()

  test "invalid UTF-8 sequence close code":
    let closeReason = "i want to close\xc0\xaf"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == "/ws"

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      await ws.close(reason = closeReason)
      await waitForClose(ws)

    server = HttpServer.create(
      address,
      handle,
      flags = {ReuseAddr})
    server.start()

    let session = await WebSocket.connect(
      "127.0.0.1:8888",
      path = "/ws",
      protocols = @["proto"]
    )

    expect WSInvalidUTF8:
      let data = await session.recvMsg()
