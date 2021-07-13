## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os
import pkg/[chronos, stew/byteutils, stew/io2]
import ../asyncunit
import ../../websock/websock, ../helpers
import ../../websock/extensions/compression/deflate

const
  dataFolder = "tests" / "extensions" / "data"

suite "permessage deflate compression":
  var server: HttpServer
  let address = initTAddress("127.0.0.1:8888")
  let deflateFactory = deflateFactory()

  teardown:
    server.stop()
    await server.closeWait()

  test "text compression":
    let textData = io2.readAllBytes(dataFolder / "alice29.txt").get()
    proc handle(request: HttpRequest) {.async.} =
      let server = WSServer.new(
        protos = ["proto"],
        factories = [deflateFactory],
      )
      let ws = await server.handleRequest(request)

      while ws.readyState != ReadyState.Closed:
        let recvData = await ws.recv()
        if ws.readyState == ReadyState.Closed:
          break
        await ws.send(recvData,
          if ws.binary: Opcode.Binary else: Opcode.Text)

    server = HttpServer.create(
      address,
      handle,
      flags = {ReuseAddr})
    server.start()

    let client = await WebSocket.connect(
      host = "127.0.0.1:8888",
      path = "/ws",
      protocols = @["proto"],
      factories = @[deflateFactory]
    )

    await client.send(textData, Opcode.Text)

    var recvData: seq[byte]
    while recvData.len < textData.len:
      let res = await client.recv()
      recvData.add res
      if client.readyState == ReadyState.Closed:
        break

    check textData == recvData
    await client.close()

  test "binary data compression":
    let binaryData = io2.readAllBytes(dataFolder / "fireworks.jpg").get()
    proc handle(request: HttpRequest) {.async.} =
      let server = WSServer.new(
        protos = ["proto"],
        factories = [deflateFactory],
      )
      let ws = await server.handleRequest(request)
      while ws.readyState != ReadyState.Closed:
        let recvData = await ws.recv()
        if ws.readyState == ReadyState.Closed:
          break
        await ws.send(recvData,
          if ws.binary: Opcode.Binary else: Opcode.Text)

    server = HttpServer.create(
      address,
      handle,
      flags = {ReuseAddr})
    server.start()

    let client = await WebSocket.connect(
      host = "127.0.0.1:8888",
      path = "/ws",
      protocols = @["proto"],
      factories = @[deflateFactory]
    )

    await client.send(binaryData, Opcode.Binary)

    var recvData: seq[byte]
    while recvData.len < binaryData.len:
      let res = await client.recv()
      recvData.add res
      if client.readyState == ReadyState.Closed:
        break

    check binaryData == recvData

    await client.close()
