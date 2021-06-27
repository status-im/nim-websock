## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/strutils
import pkg/[chronos, stew/byteutils]

import ../../ws/ws
import ../asyncunit

type
  ExtHandler = proc(ext: Ext, frame: Frame): Future[Frame] {.raises: [Defect].}

  HelperExtension = ref object of Ext
    handler*: ExtHandler

proc new*(
  T: typedesc[HelperExtension],
  handler: ExtHandler,
  session: WSSession = nil): HelperExtension =
  HelperExtension(
    handler: handler,
    name: "HelperExtension")

method decode*(
  self: HelperExtension,
  frame: Frame): Future[Frame] {.async.} =
  return await self.handler(self, frame)

method encode*(
  self: HelperExtension,
  frame: Frame): Future[Frame] {.async.} =
  return await self.handler(self, frame)

const TestString = "Hello"

suite "Encode frame extensions flow":
  test "should call extension on encode":
    var data = ""
    proc toUpper(ext: Ext, frame: Frame): Future[Frame] {.async.} =
      checkpoint "toUpper executed"
      data = string.fromBytes(frame.data).toUpper()
      check TestString.toUpper() == data
      frame.data = data.toBytes()
      return frame

    var frame = Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: TestString.toBytes())

    discard await frame.encode(@[HelperExtension.new(toUpper).Ext])
    check frame.data == TestString.toUpper().toBytes()

  test "should call extensions in correct order on encode":
    var count = 0
    proc first(ext: Ext, frame: Frame): Future[Frame] {.async.} =
      checkpoint "first executed"
      check count == 0
      count.inc

      return frame

    proc second(ext: Ext, frame: Frame): Future[Frame] {.async.} =
      checkpoint "second executed"
      check count == 1
      count.inc

      return frame

    var frame = Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: TestString.toBytes())

    discard await frame.encode(@[
        HelperExtension.new(first).Ext,
        HelperExtension.new(second).Ext])

    check count == 2

  test "should allow modifying frame headers":
    proc changeHeader(ext: Ext, frame: Frame): Future[Frame] {.async.} =
      checkpoint "changeHeader executed"
      frame.rsv1 = true
      frame.rsv2 = true
      frame.rsv3 = true
      frame.opcode = Opcode.Binary
      return frame

    var frame = Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text, # fragments have to be `Continuation` frames
      mask: false,
      data: TestString.toBytes())

    discard await frame.encode(@[HelperExtension.new(changeHeader).Ext])
    check:
      frame.rsv1 == true
      frame.rsv2 == true
      frame.rsv2 == true
      frame.opcode == Opcode.Binary

suite "Decode frame extensions flow":
  var
    address: TransportAddress
    server: StreamServer
    maskKey = genMaskKey(newRng())
    transport: StreamTransport
    reader: AsyncStreamReader
    frame: Frame

  setup:
    server = createStreamServer(
      initTAddress("127.0.0.1:0"),
      flags = {ServerFlags.ReuseAddr})
    address = server.localAddress()

  teardown:
    await transport.closeWait()
    await server.closeWait()
    server.stop()

  test "should call extension on decode":
    var data = ""
    proc toUpper(ext: Ext, frame: Frame): Future[Frame] {.async.} =
      checkpoint "toUpper executed"
      try:
        var buf = newSeq[byte](frame.length)
        # read data
        await reader.readExactly(addr buf[0], buf.len)
        if frame.mask:
          mask(buf, maskKey)
          frame.mask = false # we can reset the mask key here

        data = string.fromBytes(buf).toUpper()
        check:
          TestString.toUpper() == data

        frame.data = data.toBytes()
        return frame
      except CatchableError as exc:
        checkpoint exc.msg
        check false

    proc acceptHandler() {.async, gcsafe.} =
      let transport = await server.accept()
      reader = newAsyncStreamReader(transport)
      frame = await Frame.decode(
        reader,
        false,
        @[HelperExtension.new(toUpper).Ext])

      await reader.closeWait()
      await transport.closeWait()

    let handlerWait = acceptHandler()
    var encodedFrame = (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: true,
      maskKey: maskKey,
      data: TestString.toBytes())
      .encode())

    transport = await connect(address)
    let wrote = await transport.write(encodedFrame)

    await handlerWait
    check:
      wrote == encodedFrame.len
      frame.data == TestString.toUpper().toBytes()

  test "should call extensions in reverse order on decode":
    var count = 0
    proc first(ext: Ext, frame: Frame): Future[Frame] {.async.} =
      checkpoint "first executed"
      check count == 1
      count.inc

      return frame

    proc second(ext: Ext, frame: Frame): Future[Frame] {.async.} =
      checkpoint "second executed"
      check count == 0
      count.inc

      return frame

    proc acceptHandler() {.async, gcsafe.} =
      let transport = await server.accept()
      reader = newAsyncStreamReader(transport)
      frame = await Frame.decode(
        reader,
        false,
        @[HelperExtension.new(first).Ext,
          HelperExtension.new(second).Ext])

      await reader.closeWait()
      await transport.closeWait()

    let handlerWait = acceptHandler()
    var encodedFrame = (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: true,
      maskKey: maskKey,
      data: TestString.toBytes())
      .encode())

    let transport = await connect(address)
    let wrote = await transport.write(encodedFrame)

    await handlerWait
    check:
      wrote == encodedFrame.len
      count == 2

  test "should allow modifying frame headers":
    proc changeHeader(ext: Ext, frame: Frame): Future[Frame] {.async.} =
      checkpoint "changeHeader executed"
      frame.rsv1 = false
      frame.rsv2 = false
      frame.rsv3 = false
      frame.opcode = Opcode.Binary

      return frame

    proc acceptHandler() {.async, gcsafe.} =
      let transport = await server.accept()
      reader = newAsyncStreamReader(transport)
      frame = await Frame.decode(
        reader,
        false,
        @[HelperExtension.new(changeHeader).Ext])

      check:
        frame.rsv1 == false
        frame.rsv2 == false
        frame.rsv2 == false
        frame.opcode == Opcode.Binary

      await reader.closeWait()
      await transport.closeWait()

    let handlerWait = acceptHandler()
    var encodedFrame = (await Frame(
      fin: false,
      rsv1: true,
      rsv2: true,
      rsv3: true,
      opcode: Opcode.Text,
      mask: true,
      maskKey: maskKey,
      data: TestString.toBytes())
      .encode())

    let transport = await connect(address)
    let wrote = await transport.write(encodedFrame)

    await handlerWait
    check:
      wrote == encodedFrame.len
