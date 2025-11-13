## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import
  chronos,
  chronicles,
  results,
  stew/[byteutils, endians2, objects],
  ./types

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
    data[i] = (data[i] xor maskKey[(offset + i) mod 4])

template remainder*(frame: Frame): uint64 =
  frame.length - frame.consumed

proc read*(
    frame: Frame, reader: AsyncStreamReader, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =

  # read data from buffered payload if available
  # e.g. data processed by extensions
  var readLen = 0
  if frame.offset < frame.data.len:
    readLen = min(frame.data.len - frame.offset, nbytes)
    copyMem(pbytes, addr frame.data[frame.offset], readLen)
    frame.offset += readLen

    if frame.offset == frame.data.len:
      frame.data.reset()

  let pbuf = cast[ptr UncheckedArray[byte]](pbytes)
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
    frame: Frame, extensions: seq[Ext] = @[]
): Future[seq[byte]] {.
    async: (raises: [CancelledError, AsyncStreamError, WebSocketError])
.} =
  ## Encodes a frame into a string buffer.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  var f = frame
  if extensions.len > 0:
    for ext in extensions:
      f = await ext.encode(f)

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
    extensions: seq[Ext] = @[],
): Future[Frame] {.async: (raises: [CancelledError, AsyncStreamError, WebSocketError]).} =
  ## Read and Decode incoming header
  ##

  var header {.noinit.}: array[2, byte]
  trace "Reading new frame"
  await reader.readExactly(addr header[0], 2)

  let b0 = header[0]
  let b1 = header[1]

  var frame = Frame()
  # Read the flags and fin from the header.

  let hf = cast[HeaderFlags](b0 shr 4)
  frame.fin = HeaderFlag.fin in hf
  frame.rsv1 = HeaderFlag.rsv1 in hf
  frame.rsv2 = HeaderFlag.rsv2 in hf
  frame.rsv3 = HeaderFlag.rsv3 in hf

  if not checkedEnumAssign(frame.opcode, b0 and 0x0f):
    raise newException(WSOpcodeMismatchError, "Wrong opcode!")

  # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
  let headerLen = b1 and 0x7f
  frame.length =
    if headerLen == 0x7e:
      # Length must be 7+16 bits.
      var length {.noinit.}: array[2, byte]
      await reader.readExactly(addr length[0], length.len)
      uint64(uint16.fromBytesBE(length))
    elif headerLen == 0x7f:
      # Length must be 7+64 bits.
      var length {.noinit.}: array[8, byte]
      await reader.readExactly(addr length[0], length.len)
      uint64.fromBytesBE(length)
    else:
      # Length must be 7 bits.
      uint64(headerLen)

  if frame.length > WSMaxMessageSize:
    raise newException(WSPayloadLengthError, "Frame too big: " & $frame.length)

  # Do we need to apply mask?
  frame.mask = (b1 and 0x80) == 0x80
  if masked == frame.mask:
    # Server sends unmasked but accepts only masked.
    # Client sends masked but accepts only unmasked.
    raise newException(WSMaskMismatchError, "Socket mask mismatch")

  if frame.mask:
    # Read the mask.
    await reader.readExactly(addr frame.maskKey[0], 4)

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
