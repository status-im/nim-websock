## Nim-Libp2p
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/[chronos, chronicles, stew/endians2, stew/results]
import ./errors

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

type
  Opcode* {.pure.} = enum
    ## 4 bits. Defines the interpretation of the "Payload data".
    Cont = 0x0   ## Denotes a continuation frame.
    Text = 0x1   ## Denotes a text frame.
    Binary = 0x2 ## Denotes a binary frame.
    # 3-7 are reserved for further non-control frames.
    Close = 0x8  ## Denotes a connection close.
    Ping = 0x9   ## Denotes a ping.
    Pong = 0xa   ## Denotes a pong.
    # B-F are reserved for further control frames.

  HeaderFlag* {.pure, size: sizeof(uint8).} = enum
    rsv3
    rsv2
    rsv1
    fin

  HeaderFlags = set[HeaderFlag]

  MaskKey = array[4, char]

  Frame* = ref object
    fin*: bool                 ## Indicates that this is the final fragment in a message.
    rsv1*: bool                ## MUST be 0 unless negotiated that defines meanings
    rsv2*: bool                ## MUST be 0
    rsv3*: bool                ## MUST be 0
    opcode*: Opcode            ## Defines the interpretation of the "Payload data".
    mask*: bool                ## Defines whether the "Payload data" is masked.
    data*: seq[byte]           ## Payload data
    maskKey*: MaskKey          ## Masking key
    length*: uint64            ## Message size.
    consumed*: uint64          ## how much has been consumed from the frame

proc mask*(
  data: var openArray[byte],
  maskKey: MaskKey,
  offset = 0) =
  ## Unmask a data payload using key
  ##

  for i in 0 ..< data.len:
    data[i] = (data[i].uint8 xor maskKey[(offset + i) mod 4].uint8)

proc encode*(f: Frame, offset = 0): seq[byte] =
  ## Encodes a frame into a string buffer.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  var ret: seq[byte]
  var b0 = (f.opcode.uint8 and 0x0F) # 0th byte: opcodes and flags.
  if f.fin:
    b0 = b0 or 128'u8

  ret.add(b0)

  # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
  # 1st byte: payload len start and mask bit.
  var b1 = 0'u8

  if f.data.len <= 125:
    b1 = f.data.len.uint8
  elif f.data.len > 125 and f.data.len <= 0xFFFF:
    b1 = 126'u8
  else:
    b1 = 127'u8

  if f.mask:
    b1 = b1 or (1 shl 7)

  ret.add(uint8 b1)

  # Only need more bytes if data len is 7+16 bits, or 7+64 bits.
  if f.data.len > 125 and f.data.len <= 0xFFFF:
    # Data len is 7+16 bits.
    var len = f.data.len.uint16
    ret.add ((len shr 8) and 0xFF).uint8
    ret.add (len and 0xFF).uint8
  elif f.data.len > 0xFFFF:
    # Data len is 7+64 bits.
    var len = f.data.len.uint64
    ret.add(len.toBytesBE())

  var data = f.data

  if f.mask:
    # If we need to mask it generate random mask key and mask the data.
    mask(data, f.maskKey, offset)

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
  masked: bool):
  Future[Frame] {.async.} =
  ## Read and Decode incoming header
  ##

  var header = newSeq[byte](2)
  await reader.readExactly(addr header[0], 2)
  if header.len != 2:
    debug "Invalid websocket header length"
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
  if opcode > ord(Opcode.high):
    raise newException(WSOpcodeMismatchError, "Wrong opcode!")

  frame.opcode = (opcode).Opcode

  # If any of the rsv are set close the socket.
  if frame.rsv1 or frame.rsv2 or frame.rsv3:
    raise newException(WSRsvMismatchError, "WebSocket rsv mismatch")

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

  return frame
