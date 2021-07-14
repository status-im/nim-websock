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
    chronos,
    chronicles,
    zlib],
  ../../types,
  ../../frame

logScope:
  topics = "websock deflate"

type
  DeflateOpts = object
    isServer: bool
    decompressLimit: int          # max allowed decompression size
    threshold: int                # size in bytes below which messages
                                  # should not be compressed.
    level: ZLevel                 # compression level
    strategy: ZStrategy           # compression strategy
    memLevel: ZMemLevel           # hint for zlib memory consumption
    serverNoContextTakeOver: bool
    clientNoContextTakeOver: bool
    serverMaxWindowBits: int
    clientMaxWindowBits: int

  ContextState {.pure.} = enum
    Invalid
    Initialized
    Reset

  DeflateExt = ref object of Ext
    paramStr      : string
    opts          : DeflateOpts
    compressedMsg : bool
    compCtx       : ZStream
    compCtxState  : ContextState
    decompCtx     : ZStream
    decompCtxState: ContextState

const
  extID = "permessage-deflate"
  TrailingBytes = [0x00.byte, 0x00.byte, 0xff.byte, 0xff.byte]
  ExtDeflateThreshold* = 1024
  ExtDeflateDecompressLimit* = 10 shl 20  # 10mb

proc concatParam(resp: var string, param: string) =
  resp.add "; "
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

proc createParams(args: seq[ExtParam],
                    opts: var DeflateOpts): Result[string, string] =
  # besides validating extensions params, this proc
  # also constructing extension params for response
  var resp = ""
  for arg in args:
    case arg.name
    of "server_no_context_takeover":
      if arg.value.len > 0:
        return err("'server_no_context_takeover' should have no param")
      opts.serverNoContextTakeOver = true
      if opts.isServer:
        concatParam(resp, arg.name)
    of "client_no_context_takeover":
      if arg.value.len > 0:
        return err("'client_no_context_takeover' should have no param")
      opts.clientNoContextTakeOver = true
      if opts.isServer:
        concatParam(resp, arg.name)
    of "server_max_window_bits":
      let res = validateWindowBits(arg, opts.serverMaxWindowBits)
      if res.isErr:
        return res
      if opts.isServer:
        concatParam(resp, arg.name)
        if opts.serverMaxWindowBits == 8:
          # zlib does not support windowBits == 8
          resp.add "=9"
        else:
          resp.add res.get()
    of "client_max_window_bits":
      let res = validateWindowBits(arg, opts.clientMaxWindowBits)
      if res.isErr:
        return res
      if not opts.isServer:
        concatParam(resp, arg.name)
        if opts.clientMaxWindowBits == 8:
          # zlib does not support windowBits == 8
          resp.add "=9"
        else:
          resp.add res.get()
    else:
      return err("unrecognized param: " & arg.name)

  ok(resp)

proc getWindowBits(opts: DeflateOpts, isServer: bool): ZWindowBits =
  if isServer:
    if opts.serverMaxWindowBits == 0:
      Z_RAW_DEFLATE
    else:
      ZWindowBits(-opts.serverMaxWindowBits)
  else:
    if opts.clientMaxWindowBits == 0:
      Z_RAW_DEFLATE
    else:
      ZWindowBits(-opts.clientMaxWindowBits)

proc getContextTakeover(opts: DeflateOpts, isServer: bool): bool =
  if isServer:
    opts.serverNoContextTakeOver
  else:
    opts.clientNoContextTakeOver

proc decompressInit(ext: DeflateExt) =
  # server decompression using `client_` prefixed config
  # client decompression using `server_` prefixed config
  let windowBits = getWindowBits(ext.opts, not ext.opts.isServer)
  doAssert(ext.decompCtx.inflateInit2(windowBits) == Z_OK)
  ext.decompCtxState = ContextState.Initialized

proc compressInit(ext: DeflateExt) =
  # server compression using `server_` prefixed config
  # client compression using `client_` prefixed config
  let windowBits = getWindowBits(ext.opts, ext.opts.isServer)
  doAssert(ext.compCtx.deflateInit2(
    level = ext.opts.level,
    meth  = Z_DEFLATED,
    windowBits,
    memLevel = ext.opts.memLevel,
    strategy = ext.opts.strategy) == Z_OK
  )
  ext.compCtxState = ContextState.Initialized

proc compress(zs: var ZStream, data: openArray[byte]): seq[byte] =
  var buf: array[0xFFFF, byte]

  # these casting is needed to prevent compilation
  # error with CLANG
  zs.next_in   = cast[ptr cuchar](data[0].unsafeAddr)
  zs.avail_in  = data.len.cuint

  while true:
    zs.next_out  = cast[ptr cuchar](buf[0].addr)
    zs.avail_out = buf.len.cuint

    let r = zs.deflate(Z_SYNC_FLUSH)
    let outSize = buf.len - zs.avail_out.int
    result.add toOpenArray(buf, 0, outSize-1)

    if r == Z_STREAM_END:
      break
    elif r == Z_OK:
      # need more input or more output available
      if zs.avail_in > 0 or zs.avail_out == 0:
        continue
      else:
        break
    else:
      raise newException(WSExtError, "compression error " & $r)

proc decompress(zs: var ZStream, limit: int, data: openArray[byte]): seq[byte] =
  var buf: array[0xFFFF, byte]

  # these casting is needed to prevent compilation
  # error with CLANG
  zs.next_in   = cast[ptr cuchar](data[0].unsafeAddr)
  zs.avail_in  = data.len.cuint

  while true:
    zs.next_out  = cast[ptr cuchar](buf[0].addr)
    zs.avail_out = buf.len.cuint

    let r = zs.inflate(Z_NO_FLUSH)
    let outSize = buf.len - zs.avail_out.int
    result.add toOpenArray(buf, 0, outSize-1)

    if result.len > limit:
      raise newException(WSExtError, "decompression exceeds allowed limit")

    if r == Z_STREAM_END:
      break
    elif r == Z_OK:
      # need more input or more output available
      if zs.avail_in > 0 or zs.avail_out == 0:
        continue
      else:
        break
    else:
      raise newException(WSExtError, "decompression error " & $r)

  return result

method decode(ext: DeflateExt, frame: Frame): Future[Frame] {.async.} =
  if frame.opcode notin {Opcode.Text, Opcode.Binary, Opcode.Cont}:
    # only data frames can be decompressed
    return frame

  if frame.opcode in {Opcode.Text, Opcode.Binary}:
    # we want to know if this message is compressed or not
    # if the frame opcode is text or binary, it should also the first frame
    ext.compressedMsg = frame.rsv1
    # clear rsv1 bit because we already done with it
    frame.rsv1 = false

  if not ext.compressedMsg:
    # don't bother with uncompressed message
    return frame

  if ext.decompCtxState == ContextState.Invalid:
    ext.decompressInit()

  # even though the frame.data.len == 0, the stream needs
  # to be closed with trailing bytes if it's a final frame

  var data: seq[byte]
  var buf: array[0xFFFF, byte]

  while data.len < frame.length.int:
    let len = min(frame.length.int - data.len, buf.len)
    let read = await frame.read(ext.session.stream.reader, addr buf[0], len)
    data.add toOpenArray(buf, 0, read - 1)

    if data.len > ext.session.frameSize:
      raise newException(WSPayloadTooLarge, "payload exceeds allowed max frame size")

  if frame.fin:
    data.add TrailingBytes

  frame.data = decompress(ext.decompCtx, ext.opts.decompressLimit, data)
  trace "DeflateExt decompress", input=frame.length, output=frame.data.len

  frame.length = frame.data.len.uint64
  frame.offset = 0
  frame.consumed = 0
  frame.mask = false # clear mask flag, decompressed content is not masked

  if frame.fin:
    # server decompression using `client_` prefixed config
    # client decompression using `server_` prefixed config
    let noContextTakeover = getContextTakeover(ext.opts, not ext.opts.isServer)
    if noContextTakeover:
      doAssert(ext.decompCtx.inflateReset() == Z_OK)
      ext.decompCtxState = ContextState.Reset

  return frame

method encode(ext: DeflateExt, frame: Frame): Future[Frame] {.async.} =
  if frame.opcode notin {Opcode.Text, Opcode.Binary, Opcode.Cont}:
    # only data frames can be compressed
    return frame

  if frame.opcode in {Opcode.Text, Opcode.Binary}:
    # we only set rsv1 bit to true if the message is compressible
    # and only set the first frame's rsv1
    # if the frame opcode is text or binary, it should also the first frame
    ext.compressedMsg = frame.data.len >= ext.opts.threshold
    frame.rsv1 = ext.compressedMsg

  if not ext.compressedMsg:
    # don't bother with incompressible message
    return frame

  if ext.compCtxState == ContextState.Invalid:
    ext.compressInit()

  frame.length = frame.data.len.uint64
  frame.data = compress(ext.compCtx, frame.data)
  trace "DeflateExt compress", input=frame.length, output=frame.data.len

  if frame.fin:
    # remove trailing bytes
    when not defined(release):
      var trailer: array[4, byte]
      trailer[0] = frame.data[^4]
      trailer[1] = frame.data[^3]
      trailer[2] = frame.data[^2]
      trailer[3] = frame.data[^1]
      doAssert trailer == TrailingBytes
    frame.data.setLen(frame.data.len - 4)

  frame.length = frame.data.len.uint64
  frame.offset = 0
  frame.consumed = 0

  if frame.fin:
    # server compression using `server_` prefixed config
    # client compression using `client_` prefixed config
    let noContextTakeover = getContextTakeover(ext.opts, ext.opts.isServer)
    if noContextTakeover:
      doAssert(ext.compCtx.deflateReset() == Z_OK)
      ext.compCtxState = ContextState.Reset

  return frame

method toHttpOptions(ext: DeflateExt): string =
  # using paramStr here is a bit clunky
  extID & ext.paramStr

proc destroyExt(ext: DeflateExt) =
  if ext.compCtxState != ContextState.Invalid:
    # zlib.deflateEnd somehow return DATA_ERROR
    # when compression succeed some cases.
    # we forget to do something?
    discard ext.compCtx.deflateEnd()
    ext.compCtxState = ContextState.Invalid

  if ext.decompCtxState != ContextState.Invalid:
    doAssert(ext.decompCtx.inflateEnd() == Z_OK)
    ext.decompCtxState = ContextState.Invalid

proc makeOffer(
  clientNoContextTakeOver: bool,
  clientMaxWindowBits: int): string =

  var param = extID
  if clientMaxWindowBits in {9..15}:
    param.add "; client_max_window_bits=" & $clientMaxWindowBits
  else:
    param.add "; client_max_window_bits"

  if clientNoContextTakeOver:
    param.add "; client_no_context_takeover"

  param

proc deflateFactory*(
  threshold = ExtDeflateThreshold,
  decompressLimit = ExtDeflateDecompressLimit,
  level = Z_DEFAULT_LEVEL,
  strategy = Z_DEFAULT_STRATEGY,
  memLevel = Z_DEFAULT_MEM_LEVEL,
  clientNoContextTakeOver = false,
  clientMaxWindowBits = 15): ExtFactory =

  proc factory(isServer: bool,
       args: seq[ExtParam]): Result[Ext, string] {.
       gcsafe, raises: [Defect].} =

    # capture user configuration via closure
    var opts = DeflateOpts(
      isServer: isServer,
      threshold: threshold,
      decompressLimit: decompressLimit,
      level: level,
      strategy: strategy,
      memLevel: memLevel
    )
    let resp = createParams(args, opts)
    if resp.isErr:
      return err(resp.error)

    var ext: DeflateExt
    ext.new(destroyExt)
    ext.name          = extID
    ext.paramStr      = resp.get()
    ext.opts          = opts
    ext.compressedMsg = false
    ext.compCtxState  = ContextState.Invalid
    ext.decompCtxState= ContextState.Invalid

    ok(ext)

  ExtFactory(
    name: extID,
    factory: factory,
    clientOffer: makeOffer(
      clientNoContextTakeOver,
      clientMaxWindowBits
    )
  )
