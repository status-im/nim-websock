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
  pkg/[stew/results,
    stew/byteutils,
    chronos,
    chronicles],
  ../../websock/types,
  ../../websock/frame

type
  HexExt = ref object of Ext
    transform: bool

const
  extID = "hex"

method decode(ext: HexExt, frame: Frame): Future[Frame] {.async.} =
  if frame.opcode notin {Opcode.Text, Opcode.Binary, Opcode.Cont}:
    return frame

  if frame.opcode in {Opcode.Text, Opcode.Binary}:
    ext.transform = frame.rsv3
    frame.rsv3 = false

  if not ext.transform:
    return frame

  if frame.length > 0:
    var data: seq[byte]
    var buf: array[0xFFFF, byte]

    while data.len < frame.length.int:
      let len = min(frame.length.int - data.len, buf.len)
      let read = await frame.read(ext.session.stream.reader, addr buf[0], len)
      data.add toOpenArray(buf, 0, read - 1)

      if data.len > ext.session.frameSize:
        raise newException(WSPayloadTooLarge, "payload exceeds allowed max frame size")

    frame.data = hexToSeqByte(cast[string](data))
    trace "HexExt decode", input=frame.length, output=frame.data.len

    frame.length = frame.data.len.uint64
    frame.offset = 0
    frame.consumed = 0
    frame.mask = false

  return frame

method encode(ext: HexExt, frame: Frame): Future[Frame] {.async.} =
  if frame.opcode notin {Opcode.Text, Opcode.Binary, Opcode.Cont}:
    return frame

  if frame.opcode in {Opcode.Text, Opcode.Binary}:
    ext.transform = true
    frame.rsv3 = ext.transform

  if not ext.transform:
    return frame

  frame.length = frame.data.len.uint64
  frame.data = cast[seq[byte]](toHex(frame.data))
  trace "HexExt encode", input=frame.length, output=frame.data.len

  frame.length = frame.data.len.uint64
  frame.offset = 0
  frame.consumed = 0

  return frame

method toHttpOptions(ext: HexExt): string =
  extID

proc hexFactory*(): ExtFactory =

  proc factory(isServer: bool,
       args: seq[ExtParam]): Result[Ext, string] {.
       gcsafe, raises: [Defect].} =

    # you can capture configuration variables via closure
    # if you want

    var ext = HexExt(
      name     : extID,
      transform: false
    )

    ok(ext)

  ExtFactory(
    name: extID,
    factory: factory,
    clientOffer: extID
  )
