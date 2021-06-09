## Nim-Libp2p
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/strformat
import pkg/[chronos, chronicles, stew/byteutils, stew/endians2]
import ./types, ./frame, ./utils, ./utf8dfa, ./http

import pkg/chronos/streams/asyncstream

logScope:
  topics = "ws-session"

proc prepareCloseBody(code: StatusCodes, reason: string): seq[byte] =
  result = reason.toBytes
  if ord(code) > 999:
    result = @(ord(code).uint16.toBytesBE()) & result

proc send*(
  ws: WSSession,
  data: seq[byte] = @[],
  opcode: Opcode) {.async.} =
  ## Send a frame
  ##

  if ws.readyState == ReadyState.Closed:
    raise newException(WSClosedError, "Socket is closed!")

  logScope:
    opcode = opcode
    dataSize = data.len
    masked = ws.masked

  debug "Sending data to remote"

  var maskKey: array[4, char]
  if ws.masked:
    maskKey = genMaskKey(ws.rng)

  if opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:

    if ws.readyState in {ReadyState.Closing} and opcode notin {Opcode.Close}:
      return

    await ws.stream.writer.write(
      (await Frame(
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: opcode,
        mask: ws.masked,
        data: data, # allow sending data with close messages
        maskKey: maskKey)
        .encode()))

    return

  let maxSize = ws.frameSize
  var i = 0
  while ws.readyState notin {ReadyState.Closing}:
    let len = min(data.len, maxSize)
    let frame = Frame(
        fin: if (len + i >= data.len): true else: false,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: if i > 0: Opcode.Cont else: opcode, # fragments have to be `Continuation` frames
        mask: ws.masked,
        data: data[i ..< len + i],
        maskKey: maskKey)

    let encoded = await frame.encode(extensions = ws.extensions)
    await ws.stream.writer.write(encoded)

    i += len
    if i >= data.len:
      break

proc send*(ws: WSSession, data: string): Future[void] =
  send(ws, data.toBytes(), Opcode.Text)

proc handleClose*(
  ws: WSSession,
  frame: Frame,
  payLoad: seq[byte] = @[]) {.async.} =
  ## Handle close sequence
  ##

  logScope:
    fin = frame.fin
    masked = frame.mask
    opcode = frame.opcode
    readyState = ws.readyState

  debug "Handling close"

  if ws.readyState notin {ReadyState.Open}:
    debug "Connection isn't open, aborting close sequence!"
    return

  var
    code = StatusFulfilled
    reason = ""

  if payLoad.len == 1:
    raise newException(WSPayloadLengthError,
      "Invalid close frame with payload length 1!")

  if payLoad.len > 1:
    try:
      code = StatusCodes(uint16.fromBytesBE(payLoad[0..<2]))
    except RangeError:
      raise newException(WSInvalidCloseCodeError,
        "Status code out of range!")

    if StatusNotUsed >= code or
      code == StatusReserved1 or
      code == StatusReserved2:
      raise newException(WSInvalidCloseCodeError,
        "Can't use reserved status code")

    # remaining payload bytes are reason for closing
    reason = string.fromBytes(payLoad[2..payLoad.high])

    if not ws.binary and validateUTF8(reason) == false:
      raise newException(WSInvalidUTF8,
        "Invalid UTF8 sequence detected in close reason")

  debug "Handling close message", code, reason

  var rcode = StatusFulfilled
  var rreason = ""

  if not isNil(ws.onClose):
    try:
      (rcode, rreason) = ws.onClose(code, reason)
    except CatchableError as exc:
      debug "Exception in Close callback, this is most likely a bug", exc = exc.msg

  # don't respond to a terminated connection
  if ws.readyState != ReadyState.Closing:
    ws.readyState = ReadyState.Closing
    debug "Sending close", code = rcode, rreason
    await ws.send(prepareCloseBody(rcode, rreason), Opcode.Close)

    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()

proc handleControl*(ws: WSSession, frame: Frame) {.async.} =
  ## Handle control frames
  ##

  logScope:
    fin = frame.fin
    masked = frame.mask
    opcode = frame.opcode
    readyState = ws.readyState
    len = frame.length

  debug "Handling control frame"

  if not frame.fin:
    raise newException(WSFragmentedControlFrameError,
      "Control frame cannot be fragmented!")

  if frame.length > 125:
    raise newException(WSPayloadTooLarge,
      "Control message payload is greater than 125 bytes!")

  var payLoad = newSeq[byte](frame.length.int)
  if frame.length > 0:
    payLoad.setLen(frame.length.int)
    # Read control frame payload.
    await ws.stream.reader.readExactly(addr payLoad[0], frame.length.int)
    if frame.mask:
      mask(
        payLoad.toOpenArray(0, payLoad.high),
        frame.maskKey)

  # Process control frame payload.
  case frame.opcode:
  of Opcode.Ping:
    if not isNil(ws.onPing):
      try:
        ws.onPing(payLoad)
      except CatchableError as exc:
        debug "Exception in Ping callback, this is most likely a bug", exc = exc.msg

    # send pong to remote
    await ws.send(payLoad, Opcode.Pong)
  of Opcode.Pong:
    if not isNil(ws.onPong):
      try:
        ws.onPong(payLoad)
      except CatchableError as exc:
        debug "Exception in Pong callback, this is most likely a bug", exc = exc.msg
  of Opcode.Close:
    await ws.handleClose(frame, payLoad)
  else:
    raise newException(WSInvalidOpcodeError, "Invalid control opcode!")

proc readFrame*(ws: WSSession, extensions: seq[Ext] = @[]): Future[Frame] {.async.} =
  ## Gets a frame from the WebSocket.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2
  ##

  while ws.readyState != ReadyState.Closed:
    let frame = await Frame.decode(
      ws.stream.reader, ws.masked, extensions)

    logScope:
      opcode = frame.opcode
      len = frame.length
      mask = frame.mask
      fin = frame.fin

    debug "Decoded new frame"

    # return the current frame if it's not one of the control frames
    if frame.opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:
      await ws.handleControl(frame) # process control frames# process control frames
      continue

    return frame

proc ping*(ws: WSSession, data: seq[byte] = @[]): Future[void] =
  ws.send(data, opcode = Opcode.Ping)

proc recv*(
  ws: WSSession,
  data: pointer,
  size: int): Future[int] {.async.} =
  ## Attempts to read up to `size` bytes
  ##
  ## Read as many frames as necessary
  ## to fill the buffer until either
  ## the message ends (frame.fin) or
  ## the buffer is full.
  ##
  ## If no data is on the pipe it awaits
  ## until at least one byte is available
  ##

  var consumed = 0
  var pbuffer = cast[ptr UncheckedArray[byte]](data)
  try:
    var first = true
    if isNil(ws.frame):
      ws.frame = await ws.readFrame()

    while consumed < size:
      if isNil(ws.frame):
        debug "Empty frame, breaking"
        break

      logScope:
        fin = ws.frame.fin
        len = ws.frame.length
        consumed = ws.frame.consumed
        remainder = ws.frame.remainder
        opcode = ws.frame.opcode

      if first:
        ws.binary = ws.frame.opcode == Opcode.Binary # set binary flag
        debug "Setting binary flag", binary = ws.binary

      let len = min(ws.frame.remainder.int, size - consumed)
      if len <= 0:
        debug "Not enough bytes to read, breaking"
        break

      echo "READING FROM ", consumed
      let read = await ws.stream.reader.readOnce(addr pbuffer[consumed], len)
      if read <= 0:
        debug "Didn't read any bytes, breaking"
        break

      if ws.frame.mask:
        debug "Unmasking frame"
        # unmask data using offset
        mask(
          pbuffer.toOpenArray(consumed, (consumed + read) - 1),
          ws.frame.maskKey,
          ws.frame.consumed.int)

      consumed += read
      ws.frame.consumed += read.uint64
      first = false

      debug "Read data from frame", read
      # all has been consumed from the frame
      # read the next frame
      if ws.frame.remainder <= 0:
        if ws.frame.fin: # we're at the end of the message, break
          debug "Read all frames, breaking"
          ws.frame = nil
          break

        ws.frame = await ws.readFrame()

    # if not ws.binary and validateUTF8(pbuffer.toOpenArray(0, consumed - 1)) == false:
    #   raise newException(WSInvalidUTF8, "Invalid UTF8 sequence detected")

    return consumed
  except CatchableError as exc:
    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()
    debug "Exception reading frames", exc = exc.msg
    raise exc
  finally:
    if not isNil(ws.frame) and (ws.frame.fin and ws.frame.remainder <= 0):
      ws.frame = nil

proc recv*(
  ws: WSSession,
  size = WSMaxMessageSize): Future[seq[byte]] {.async.} =
  ## Attempt to read a full message up to max `size`
  ## bytes in `frameSize` chunks.
  ##
  ## If no `fin` flag arrives await until either
  ## cancelled or the `fin` flag arrives.
  ##
  ## If message is larger than `size` a `WSMaxMessageSizeError`
  ## exception is thrown.
  ##
  ## In all other cases it awaits a full message.
  ##
  var res: seq[byte]
  while ws.readyState != ReadyState.Closed:
    var buf = newSeq[byte](ws.frameSize)
    let read = await ws.recv(addr buf[0], buf.len)
    if read <= 0:
      break

    buf.setLen(read)
    if res.len + buf.len > size:
      raise newException(WSMaxMessageSizeError, "Max message size exceeded")

    res.add(buf)

    # no more frames
    if isNil(ws.frame):
      break

    # read the entire message, exit
    if ws.frame.fin and ws.frame.remainder().int <= 0:
      break

  return res

proc close*(
  ws: WSSession,
  code = StatusFulfilled,
  reason: string = "") {.async.} =
  ## Close the Socket, sends close packet.
  ##

  if ws.readyState != ReadyState.Open:
    return

  try:
    ws.readyState = ReadyState.Closing
    await ws.send(
      prepareCloseBody(code, reason),
      opcode = Opcode.Close)

    # read frames until closed
    while ws.readyState != ReadyState.Closed:
      discard await ws.recv()
  except CatchableError as exc:
    debug "Exception closing", exc = exc.msg
