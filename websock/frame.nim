## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/[
  chronos,
  chronicles,
  stew/byteutils,
  stew/endians2,
  stew/results]

import ./types

logScope:
  topics = "websock ws-frame"

#[
  +---------------------------------------------------------------+
  |0                   1                   2                   3  |
  |0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1|
  +-+-+-+-+-------+-+-------------+-------------------------------+
  |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
  |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
  |N|V|V|V|       |S|             |   (if payload len==126/127)   |
  | |1|2|3|       |K|             |                               |
  +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
  |     Extended payload length continued, if payload len == 127  |
  + - - - - - - - - - - - - - - - +-------------------------------+
  |                               |Masking-key, if MASK set to 1  |
  +-------------------------------+-------------------------------+
  | Masking-key (continued)       |          Payload Data         |
  +-------------------------------- - - - - - - - - - - - - - - - +
  :                     Payload Data continued ...                :
  + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
  |                     Payload Data continued ...                |
  +---------------------------------------------------------------+
]#

proc mask*(
  data: var openArray[byte],
  maskKey: MaskKey,
  offset = 0) =
  ## Unmask a data payload using key
  ##

  for i in 0 ..< data.len:
    data[i] = (data[i].uint8 xor maskKey[(offset + i) mod 4].uint8)

template remainder*(frame: Frame): uint64 =
  frame.length - frame.consumed

proc read*(
  frame: Frame,
  reader: AsyncStreamReader,
  pbytes: pointer,
  nbytes: int): Future[int] {.async.} =

  # read data from buffered payload if available
  # e.g. data processed by extensions
  var readLen = 0
  if frame.offset < frame.data.len:
    readLen = min(frame.data.len - frame.offset, nbytes)
    copyMem(pbytes, addr frame.data[frame.offset], readLen)
    frame.offset += readLen

  var pbuf = cast[ptr UncheckedArray[byte]](pbytes)
  if readLen < nbytes:
    let len  = min(nbytes - readLen, frame.remainder.int - readLen)
    readLen += await reader.readOnce(addr pbuf[readLen], len)

  if frame.mask and readLen > 0:
    # unmask data using offset
    mask(
      pbuf.toOpenArray(0, readLen - 1),
      frame.maskKey,
      frame.consumed.int)

  frame.consumed += readLen.uint64
  return readLen

proc encode*(
  frame: Frame,
  extensions: seq[Ext] = @[]): Future[seq[byte]] {.async.} =
  ## Encodes a frame into a string buffer.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  var f = frame
  if extensions.len > 0:
    for e in extensions:
      f = await e.encode(f)

  var ret: seq[byte]
  var b0 = (f.opcode.uint8 and 0x0f) # 0th byte: opcodes and flags.
  if f.fin:
    b0 = b0 or 0x80'u8
  if f.rsv1:
    b0 = b0 or 0x40'u8
  if f.rsv2:
    b0 = b0 or 0x20'u8
  if f.rsv3:
    b0 = b0 or 0x10'u8

  ret.add(b0)

  # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
  # 1st byte: payload len start and mask bit.
  var b1 = 0'u8

  if f.data.len <= 125:
    b1 = f.data.len.uint8
  elif f.data.len > 125 and f.data.len <= 0xffff:
    b1 = 126'u8
  else:
    b1 = 127'u8

  if f.mask:
    b1 = b1 or (1 shl 7)

  ret.add(uint8 b1)

  # Only need more bytes if data len is 7+16 bits, or 7+64 bits.
  if f.data.len > 125 and f.data.len <= 0xffff:
    # Data len is 7+16 bits.
    var len = f.data.len.uint16
    ret.add ((len shr 8) and 0xff).uint8
    ret.add (len and 0xff).uint8
  elif f.data.len > 0xffff:
    # Data len is 7+64 bits.
    var len = f.data.len.uint64
    ret.add(len.toBytesBE())

  var data = f.data
  if f.mask:
    # If we need to mask it generate random mask key and mask the data.
    mask(data, f.maskKey)

    # Write mask key next.
    ret.add(f.maskKey[0].uint8)
    ret.add(f.maskKey[1].uint8)
    ret.add(f.maskKey[2].uint8)
    ret.add(f.maskKey[3].uint8)

  # Write the data.
  ret.add(data)
  return ret

proc decode*(
  _: typedesc[Frame],
  reader: AsyncStreamReader,
  masked: bool,
  extensions: seq[Ext] = @[]): Future[Frame] {.async.} =
  ## Read and Decode incoming header
  ##

  var header = newSeq[byte](2)
  trace "Reading new frame"
  await reader.readExactly(addr header[0], 2)
  if header.len != 2:
    trace "Invalid websocket header length"
    raise newException(WSMalformedHeaderError,
      "Invalid websocket header length")

  let b0 = header[0].uint8
  let b1 = header[1].uint8

  var frame = Frame()
  # Read the flags and fin from the header.

  var hf = cast[HeaderFlags](b0 shr 4)
  frame.fin = HeaderFlag.fin in hf
  frame.rsv1 = HeaderFlag.rsv1 in hf
  frame.rsv2 = HeaderFlag.rsv2 in hf
  frame.rsv3 = HeaderFlag.rsv3 in hf

  let opcode = (b0 and 0x0f)
  if opcode > ord(Opcode.Pong):
    raise newException(WSOpcodeMismatchError, "Wrong opcode!")

  frame.opcode = (opcode).Opcode

  # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
  var finalLen: uint64 = 0

  let headerLen = uint(b1 and 0x7f)
  if headerLen == 0x7e:
    # Length must be 7+16 bits.
    var length = newSeq[byte](2)
    await reader.readExactly(addr length[0], 2)
    finalLen = uint16.fromBytesBE(length)
  elif headerLen == 0x7f:
    # Length must be 7+64 bits.
    var length = newSeq[byte](8)
    await reader.readExactly(addr length[0], 8)
    finalLen = uint64.fromBytesBE(length)
  else:
    # Length must be 7 bits.
    finalLen = headerLen

  frame.length = finalLen

  if frame.length > WSMaxMessageSize:
    raise newException(WSPayloadLengthError, "Frame too big: " & $frame.length)

  # Do we need to apply mask?
  frame.mask = (b1 and 0x80) == 0x80
  if masked == frame.mask:
    # Server sends unmasked but accepts only masked.
    # Client sends masked but accepts only unmasked.
    raise newException(WSMaskMismatchError,
      "Socket mask mismatch")

  var maskKey = newSeq[byte](4)
  if frame.mask:
    # Read the mask.
    await reader.readExactly(addr maskKey[0], 4)
    for i in 0..<maskKey.len:
      frame.maskKey[i] = cast[char](maskKey[i])

  if extensions.len > 0:
    for i in countdown(extensions.high, extensions.low):
      frame = await extensions[i].decode(frame)

  # we check rsv bits after extensions,
  # because they have special meaning for extensions.
  # rsv bits will be cleared by extensions if they are set by peer.
  # If any of the rsv are set close the socket.
  if frame.rsv1 or frame.rsv2 or frame.rsv3:
    raise newException(WSRsvMismatchError, "WebSocket rsv mismatch")

  return frame
