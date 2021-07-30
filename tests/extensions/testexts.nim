## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import
  pkg/[
    asynctest,
    chronos,
    httputils,
    stew/byteutils],
  ../../websock/websock,
  ../helpers,
  ./base64ext,
  ./hexext

let
  address = initTAddress("127.0.0.1:8888")
var
  server: HttpServer

suite "multiple extensions flow":
  let hexFactory = hexFactory()
  let base64Factory = base64Factory(padding = true)

  teardown:
    server.stop()
    await server.closeWait()

  test "hex to base64 ext flow":
    let testData = "hello world"
    proc handle(request: HttpRequest) {.async.} =
      let server = WSServer.new(
        protos = ["proto"],
        factories = [hexFactory, base64Factory],
      )
      let ws = await server.handleRequest(request)
      let recvData = await ws.recv()
      await ws.send(recvData,
        if ws.binary: Opcode.Binary else: Opcode.Text)

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let client = await connectClient(
      address = address,
      factories = @[hexFactory, base64Factory])

    await client.send(testData)
    let res = await client.recv()
    check testData.toBytes() == res
    await client.close()

  test "base64 to hex ext flow":
    let testData = "hello world"
    proc handle(request: HttpRequest) {.async.} =
      let server = WSServer.new(
        protos = ["proto"],
        factories = [hexFactory, base64Factory],
      )
      let ws = await server.handleRequest(request)
      let recvData = await ws.recv()
      await ws.send(recvData,
        if ws.binary: Opcode.Binary else: Opcode.Text)

      await waitForClose(ws)

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let client = await connectClient(
      address = address,
      factories = @[hexFactory, base64Factory])

    await client.send(testData)
    let res = await client.recv()
    check testData.toBytes() == res
    await client.close()
