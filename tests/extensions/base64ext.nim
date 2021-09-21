## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import
  pkg/[stew/results,
    stew/base64,
    chronos,
    chronicles],
  ../../websock/types,
  ../../websock/frame

type
  Base64Ext = ref object of Ext
    padding: bool
    transform: bool

const
  extID = "base64"

method decode(ext: Base64Ext, frame: Frame): Future[Frame] {.async.} =
  if frame.opcode notin {Opcode.Text, Opcode.Binary, Opcode.Cont}:
    return frame

  if frame.opcode in {Opcode.Text, Opcode.Binary}:
    ext.transform = frame.rsv2
    frame.rsv2 = false

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

    # bug in Base64.Decode when accepts seq[byte]
    let instr = cast[string](data)
    if ext.padding:
      frame.data = Base64Pad.decode(instr)
    else:
      frame.data = Base64.decode(instr)

    trace "Base64Ext decode", input=frame.length, output=frame.data.len

    frame.length = frame.data.len.uint64
    frame.offset = 0
    frame.consumed = 0
    frame.mask = false

  return frame

method encode(ext: Base64Ext, frame: Frame): Future[Frame] {.async.} =
  if frame.opcode notin {Opcode.Text, Opcode.Binary, Opcode.Cont}:
    return frame

  if frame.opcode in {Opcode.Text, Opcode.Binary}:
    ext.transform = true
    frame.rsv2 = ext.transform

  if not ext.transform:
    return frame

  frame.length = frame.data.len.uint64

  if ext.padding:
    frame.data = cast[seq[byte]](Base64Pad.encode(frame.data))
  else:
    frame.data = cast[seq[byte]](Base64.encode(frame.data))

  trace "Base64Ext encode", input=frame.length, output=frame.data.len

  frame.length = frame.data.len.uint64
  frame.offset = 0
  frame.consumed = 0

  return frame

method toHttpOptions(ext: Base64Ext): string =
  extID & "; pad=" & $ext.padding

proc base64Factory*(padding: bool): ExtFactory =

  proc factory(isServer: bool,
       args: seq[ExtParam]): Result[Ext, string] {.
       gcsafe, raises: [Defect].} =

    # you can capture configuration variables via closure
    # if you want

    var ext = Base64Ext(
      name     : extID,
      transform: false
    )

    for arg in args:
      if arg.name == "pad":
        ext.padding = arg.value == "true"
        break

    ok(ext)

  ExtFactory(
    name: extID,
    factory: factory,
    clientOffer: extID & "; pad=" & $padding
  )
