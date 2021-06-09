## nim-ws
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.


import
  std/[strutils],
  pkg/[stew/results, chronos],
  ../../types, ../../frame, ./miniz/miniz_api

type
  DeflateOpts = object
    isServer: bool
    serverNoContextTakeOver: bool
    clientNoContextTakeOver: bool
    serverMaxWindowBits: int
    clientMaxWindowBits: int

  DeflateExt = ref object of Ext
    paramStr: string
    opts: DeflateOpts
    # 'messageCompressed' is a two way flag:
    # 1. the original message is compressible or not
    # 2. the frame we received need decompression or not
    messageCompressed: bool

const
  extID = "permessage-deflate"

proc concatParam(resp: var string, param: string) =
  resp.add ';'
  resp.add param

proc validateWindowBits(arg: ExtParam, res: var int): Result[string, string] =
  if arg.value.len == 0:
    return ok("")

  if arg.value.len > 2:
    return err("window bits expect 2 bytes, got " & $arg.value.len)

  for n in arg.value:
    if n notin Digits:
      return err("window bits value contains illegal char: " & $n)

  var winbit = 0
  for i in 0..<arg.value.len:
    winbit = winbit * 10 + arg.value[i].int - '0'.int

  if winbit < 8 or winbit > 15:
    return err("window bits should between 8-15, got " & $winbit)

  res = winbit
  return ok("=" & arg.value)

proc validateParams(args: seq[ExtParam],
                    opts: var DeflateOpts): Result[string, string] =
  # besides validating extensions params, this proc
  # also constructing extension param for response
  var resp = ""
  for arg in args:
    case arg.name
    of "server_no_context_takeover":
      if arg.value.len > 0:
        return err("'server_no_context_takeover' should have no param")
      if opts.isServer:
        concatParam(resp, arg.name)
      opts.serverNoContextTakeOver = true
    of "client_no_context_takeover":
      if arg.value.len > 0:
        return err("'client_no_context_takeover' should have no param")
      if opts.isServer:
        concatParam(resp, arg.name)
      opts.clientNoContextTakeOver = true
    of "server_max_window_bits":
      if opts.isServer:
        concatParam(resp, arg.name)
      let res = validateWindowBits(arg, opts.serverMaxWindowBits)
      if res.isErr:
        return res
      resp.add res.get()
    of "client_max_window_bits":
      if opts.isServer:
        concatParam(resp, arg.name)
      let res = validateWindowBits(arg, opts.clientMaxWindowBits)
      if res.isErr:
        return res
      resp.add res.get()
    else:
      return err("unrecognized param: " & arg.name)

  ok(resp)

method decode*(ext: DeflateExt, data: seq[byte]): Future[seq[byte]] {.async.} =
  if not ext.messageCompressed:
    return data

  # TODO: append trailing bytes
  var mz = MzStream(
    next_in: cast[ptr cuchar](data[0].unsafeAddr),
    avail_in: data.len.cuint
  )

  let windowBits = if ext.opts.serverMaxWindowBits == 0:
                     MZ_DEFAULT_WINDOW_BITS
                   else:
                     MzWindowBits(ext.opts.serverMaxWindowBits)

  doAssert(mz.inflateInit2(windowBits) == MZ_OK)
  var res: seq[byte]
  var buf: array[0xFFFF, byte]

  while true:
    mz.next_out  = cast[ptr cuchar](buf[0].addr)
    mz.avail_out = buf.len.cuint
    let r = mz.inflate(MZ_SYNC_FLUSH)
    let outSize = buf.len - mz.avail_out.int
    res.add toOpenArray(buf, 0, outSize-1)
    if r == MZ_STREAM_END:
      break
    elif r == MZ_OK:
      continue
    else:
      doAssert(false, "decompression error")

  doAssert(mz.inflateEnd() == MZ_OK)
  return res

method encode*(ext: DeflateExt, data: seq[byte]): Future[seq[byte]] {.async.} =
  var mz = MzStream(
    next_in: cast[ptr cuchar](data[0].unsafeAddr),
    avail_in: data.len.cuint
  )

  let windowBits = if ext.opts.serverMaxWindowBits == 0:
                     MZ_DEFAULT_WINDOW_BITS
                   else:
                     MzWindowBits(ext.opts.serverMaxWindowBits)

  doAssert(mz.deflateInit2(
    level = MZ_DEFAULT_LEVEL,
    meth  = MZ_DEFLATED,
    windowBits,
    1,
    strategy = MZ_DEFAULT_STRATEGY) == MZ_OK
  )

  let maxSize = mz.deflateBound(data.len.culong).int
  var res: seq[byte]
  var buf: array[0xFFFF, byte]

  while true:
    mz.next_out  = cast[ptr cuchar](buf[0].addr)
    mz.avail_out = buf.len.cuint
    let r = mz.deflate(MZ_FINISH)
    let outSize = buf.len - mz.avail_out.int
    res.add toOpenArray(buf, 0, outSize-1)
    if r == MZ_STREAM_END:
      break
    elif r == MZ_OK:
      continue
    else:
      doAssert(false, "compression error")

  # TODO: cut trailing bytes
  doAssert(mz.deflateEnd() == MZ_OK)
  ext.messageCompressed = res.len < data.len
  if ext.messageCompressed:
    return res
  else:
    return data

method decode(ext: DeflateExt, frame: Frame): Future[Frame] {.async.} =
  if frame.opcode in {Opcode.Text, Opcode.Binary}:
    # only data frame can be compressed
    # and we want to know if this message is compressed or not
    # if the frame opcode is text or binary, it should also the first frame
    ext.messageCompressed = frame.rsv1
    # clear rsv1 bit because we already done with it
    frame.rsv1 = false
  return frame

method encode(ext: DeflateExt, frame: Frame): Future[Frame] {.async.} =
  if frame.opcode in {Opcode.Text, Opcode.Binary}:
    # only data frame can be compressed
    # and we only set rsv1 bit to true if the message is compressible
    # if the frame opcode is text or binary, it should also the first frame
    frame.rsv1 = ext.messageCompressed
  return frame

method toHttpOptions(ext: DeflateExt): string =
  # using paramStr here is a bit clunky
  extID & "; " & ext.paramStr

proc deflateExtFactory(isServer: bool, args: seq[ExtParam]): Result[Ext, string] {.raises: [Defect].} =
  var opts = DeflateOpts(isServer: isServer)
  let resp = validateParams(args, opts)
  if resp.isErr:
    return err(resp.error)
  let ext = DeflateExt(
    name: extID,
    paramStr: resp.get(),
    opts: opts
  )
  ok(ext)

const
  deflateFactory* = (extID, deflateExtFactory)
