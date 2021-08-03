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
    asynctest,
    chronos,
    httputils,
    stew/byteutils],
  ./helpers,
  ../websock/[websock, utf8dfa]

let
  address = initTAddress("127.0.0.1:8888")
var
  server: HttpServer

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

suite "UTF-8 validator in action recv() vs. recv2()":
  teardown:
    server.stop()
    await server.closeWait()

  test "recv2() accept valid UTF-8 sequence":
    let testData = "hello world"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)

      let res = await ws.recv2()
      check:
        string.fromBytes(res) == testData
        ws.binary == false

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await connectClient(
      address = address)

    await session.send(testData)
    await session.close()

  test "recv2() accept valid UTF-8 sequence in close reason":
    let testData = "hello world"
    let closeReason = "i want to close"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

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
      let res = await ws.recv2()
      await waitForClose(ws)

      check:
        string.fromBytes(res) == testData
        ws.binary == false

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await connectClient(
      address = address)

    await session.send(testData)
    await session.close(reason = closeReason)

  test "recv2() reject invalid UTF-8 sequence":
    let testData = "hello world\xc0\xaf"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      await ws.send(testData)
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await connectClient(
      address = address)

    expect WSInvalidUTF8:
      discard await session.recv2()

  test "recv() accept invalid UTF-8 sequence":
    let testData = "hello world\xc0\xaf"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let server = WSServer.new(protos = ["proto"])
      let ws = await server.handleRequest(request)
      await ws.send(testData)
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await connectClient(
      address = address)

    discard await session.recv()

  test "recv2() oblivious of invalid UTF-8 sequence close code":
    let closeReason = "i want to close\xc0\xaf"
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let ws = await WSServer.new.handleRequest(request)
      await ws.close(
        reason = closeReason)
      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await connectClient(
      address = address)

    let data = await session.recv2()
    check data == newSeq[byte](0)

  test "detect invalid UTF-8 sequence close code":
    let closeReason = "i want to close\xc0\xaf"
    const CloseStatus = StatusCodes(4444)

    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      # Send invalid utf8 reason code
      let ws = await WSServer.new.handleRequest(request)
      await ws.close(
        code = CloseStatus,
        reason = closeReason)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    # Catch reason code throug closure variables
    var
      onCloseStatus: StatusCodes  # this one is for completeness, only
      onCloseReason: string       # this is the one of interested

    let client = await connectClient(
      address = address,
      onClose = proc(status: StatusCodes, reason: string): CloseResult =
                    onCloseStatus = status
                    onCloseReason = reason)

    let data = await client.recv()
    await client.waitForClose

    check client.readyState == ReadyState.Closed
    check client.binary == false
    check onCloseStatus == CloseStatus
    check onCloseReason == closeReason

    # Reason code not accessible with recv()/recv2()
    check data == newSeq[byte](0)

    # This one verifies the reason code
    check onCloseReason.validateUTF8 == false

  test "recv2() sequence pairs, frame boundary inside UTF-8 code point":
    const
      validUtf8Text = "12345\xF4\x8F\xBF\xBF12345xxxxx"

      # Frame size to be used for this test
      frameSize = 7

      # Fetching data using buffers of this size, making it smaller than
      # `frameSize` gives an extra challenge
      chunkLen = frameSize - 2

      # FIXME: for some reason, the data must be a multiple of the `frameSize`
      #        otherwise the system crashes, most probably in the server
      #        === needs further investigation?
      dataLen = frameSize * (validUtf8Text.len div frameSize)
      testData = validUtf8Text[0 ..< datalen]

    # Make sure that the `frameSize` is in the middle of a code point.
    check frameSize < testData.len
    check 127.char < testData[frameSize - 1] and 127.char < testData[frameSize]

    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let
        server = WSServer.new()
        ws = await server.handleRequest(request)

      var res, vetted, tail: seq[byte]
      while ws.readystate != ReadyState.Closed:
        (vetted, tail) = await ws.recv2(prequel = tail, size = frameSize)
        res.add vetted

      check string.fromBytes(res) == testData

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let client = await connectClient(
      address = address,
      frameSize = frameSize)

    await client.send(testData)
    await client.close

  test "recv2() rejects utf8 text chunk w/boundary inside UTF-8 code point":
    const
      validUtf8Text = "12345\xF4\x8F\xBF\xBF12345xxxxx"
      frameSize = 8
      chunkLen = frameSize - 1
      dataLen = frameSize * (validUtf8Text.len div frameSize)
      testData = validUtf8Text[0 ..< datalen]

    # Make sure that the `frameSize` is in the middle of a code point.
    check frameSize < testData.len
    check 127.char < testData[frameSize - 1] and 127.char < testData[frameSize]

    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath

      let ws = await WSServer.new.handleRequest(request)
      var rejectedOk = false
      try:
        let res = await ws.recv2(size = chunkLen)
      except WSInvalidUTF8:
        rejectedOk = true

      check rejectedOk == true

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let client = await connectClient(
      address = address,
      frameSize = frameSize)

    await client.send(testData)
    await client.close

# End
