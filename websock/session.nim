## nim-websock
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
  topics = "websock ws-session"

proc updateReadMode(ws: WSSession): bool =
  ## This helper function sets text/binary mode for the first frame and
  ## verifies consistency for others.
  ##
  ## Return value `false` indicates unconfirmed mode switch `text` <=> `binary`

  if not ws.frame.isNil:
    # Very first frame, take encoding at face value.
    if not ws.seen:
      ws.binary = ws.frame.opcode != Opcode.Text
      ws.seen = true

    # Illegal mode switch
    elif ws.binary and ws.frame.opcode == Opcode.Text:
      return false
    elif not ws.binary and ws.frame.opcode == Opcode.Binary:
      return false

  true

proc prepareCloseBody(code: StatusCodes, reason: string): seq[byte] =
  result = reason.toBytes
  if ord(code) > 999:
    result = @(ord(code).uint16.toBytesBE()) & result

proc writeMessage*(ws: WSSession,
  data: seq[byte] = @[],
  opcode: Opcode,
  maskKey: MaskKey,
  extensions: seq[Ext]) {.async.} =

  if opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:
    warn "Attempting to send a data frame with an invalid opcode!"
    raise newException(WSInvalidOpcodeError,
      &"Attempting to send a data frame with an invalid opcode {opcode}!")

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

    let encoded = await frame.encode(extensions)
    await ws.stream.writer.write(encoded)

    i += len
    if i >= data.len:
      break

proc writeControl*(
  ws: WSSession,
  data: seq[byte] = @[],
  opcode: Opcode,
  maskKey: MaskKey) {.async.} =
  ## Send a frame applying the supplied
  ## extensions
  ##

  logScope:
    opcode = opcode
    dataSize = data.len
    masked = ws.masked

  if opcode in {Opcode.Text, Opcode.Cont, Opcode.Binary}:
    warn "Attempting to send a control frame with an invalid opcode!"
    raise newException(WSInvalidOpcodeError,
      &"Attempting to send a control frame with an invalid opcode {opcode}!")

  let frame = Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: opcode,
      mask: ws.masked,
      data: data,
      maskKey: maskKey)

  let encoded = await frame.encode()
  await ws.stream.writer.write(encoded)

  trace "Wrote control frame"

proc send*(
  ws: WSSession,
  data: seq[byte] = @[],
  opcode: Opcode): Future[void]
  {.async, raises: [Defect, WSClosedError].} =
  ## Send a frame
  ##

  if ws.readyState == ReadyState.Closed:
    raise newException(WSClosedError, "WebSocket is closed!")

  if ws.readyState in {ReadyState.Closing} and opcode notin {Opcode.Close}:
    trace "Can only respond with Close opcode to a closing connection"
    return

  logScope:
    opcode = opcode
    dataSize = data.len
    masked = ws.masked

  trace "Sending data to remote"

  let maskKey = if ws.masked:
      genMaskKey(ws.rng)
    else:
      default(MaskKey)

  if opcode in {Opcode.Text, Opcode.Cont, Opcode.Binary}:
    await ws.writeMessage(
      data, opcode, maskKey, ws.extensions)

    return

  await ws.writeControl(data, opcode, maskKey)

proc send*(
  ws: WSSession,
  data: string): Future[void]
  {.raises: [Defect, WSClosedError].} =
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

  trace "Handling close"

  if ws.readyState != ReadyState.Open and ws.readyState != ReadyState.Closing:
    trace "Connection isn't open, aborting close sequence!"
    return

  var
    code = StatusFulfilled
    reason = ""

  case payload.len:
  of 0:
    code = StatusNoStatus
  of 1:
    raise newException(WSPayloadLengthError,
      "Invalid close frame with payload length 1!")
  else:
    try:
      code = StatusCodes(uint16.fromBytesBE(payLoad[0..<2]))
    except RangeError:
      raise newException(WSInvalidCloseCodeError,
        "Status code out of range!")

    if code in StatusNotUsed or
      code in StatusReservedProtocol:
      raise newException(WSInvalidCloseCodeError,
        &"Can't use reserved status code: {code}")

    if code == StatusReserved or
      code == StatusNoStatus or
      code == StatusClosedAbnormally:
      raise newException(WSInvalidCloseCodeError,
        &"Can't use reserved status code: {code}")

    # remaining payload bytes are reason for closing
    reason = string.fromBytes(payLoad[2..payLoad.high])

  trace "Handling close message", code = ord(code), reason
  if not isNil(ws.onClose):
    try:
      (code, reason) = ws.onClose(code, reason)
    except CatchableError as exc:
      trace "Exception in Close callback, this is most likely a bug", exc = exc.msg
  else:
    code = StatusFulfilled
    reason = ""

  # don't respond to a terminated connection
  if ws.readyState != ReadyState.Closing:
    ws.readyState = ReadyState.Closing
    trace "Sending close", code = ord(code), reason
    await ws.send(prepareCloseBody(code, reason), Opcode.Close)

    ws.readyState = ReadyState.Closed

  # TODO: Under TLS, the response takes longer
  # to depart and fails to write the resp code
  # and cleanly close the connection. Definitely
  # looks like a bug, but not sure if it's chronos
  # or us?
  await sleepAsync(10.millis)
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

  trace "Handling control frame"

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
        trace "Exception in Ping callback, this is most likely a bug", exc = exc.msg

    # send pong to remote
    await ws.send(payLoad, Opcode.Pong)
  of Opcode.Pong:
    if not isNil(ws.onPong):
      try:
        ws.onPong(payLoad)
      except CatchableError as exc:
        trace "Exception in Pong callback, this is most likely a bug", exc = exc.msg
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

    trace "Decoded new frame"

    # return the current frame if it's not one of the control frames
    if frame.opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:
      await ws.handleControl(frame) # process control frames# process control frames
      continue

    return frame

proc ping*(
  ws: WSSession,
  data: seq[byte] = @[]): Future[void]
  {.raises: [Defect, WSClosedError].} =
  ws.send(data, opcode = Opcode.Ping)

proc recv*(
  ws: WSSession,
  data: pointer,
  size: int): Future[int] {.async.} =
  ## Attempts to read up to ``size`` bytes
  ##
  ## If ``size`` is less than the data in
  ## the frame, allow reading partial frames
  ##
  ## If no data is left in the pipe await
  ## until at least one byte is available
  ##
  ## Otherwise, read as many frames as needed
  ## up to ``size`` bytes, note that we do break
  ## at message boundaries (``fin`` flag set).
  ##
  ## Processing frames, this function verifies that all message
  ## frames have the same type binary, or utf8. Otherwise an
  ## exception `WSOpcodeMismatchError` is thrown.
  ##
  ## Use this to stream data from frames
  ##

  var consumed = 0
  var pbuffer = cast[ptr UncheckedArray[byte]](data)
  try:
    if not isNil(ws.frame):
      if ws.frame.fin and ws.frame.remainder > 0:
        trace "Continue reading from the same frame"
      elif not ws.frame.fin and ws.frame.remainder > 0:
        trace "Restarting reads in the middle of a frame" &
          " in a multiframe message"
        #first = false
      elif ws.frame.fin and ws.frame.remainder <= 0:
        trace "Resetting an already consumed frame"
        ws.frame = nil
      elif not ws.frame.fin and ws.frame.remainder <= 0:
        trace "No more bytes left and message EOF, resetting frame"
        ws.frame = nil

    if isNil(ws.frame):
      ws.frame = await ws.readFrame(ws.extensions)
      if not ws.updateReadMode:
        raise newException(WSOpcodeMismatchError, "Text/binary mode switch")

    while consumed < size:
      if isNil(ws.frame):
        trace "Empty frame, breaking"
        break

      logScope:
        fin = ws.frame.fin
        len = ws.frame.length
        consumed = ws.frame.consumed
        remainder = ws.frame.remainder
        opcode = ws.frame.opcode
        masked = ws.frame.mask

      let len = min(ws.frame.remainder.int, size - consumed)
      if len > 0:
        trace "Reading bytes from frame stream", len
        let read = await:
          ws.frame.read(ws.stream.reader, addr pbuffer[consumed], len)
        if read <= 0:
          trace "Didn't read any bytes, breaking"
          break

        trace "Read data from frame", read
        consumed += read

      # all has been consumed from the frame
      # read the next frame
      if ws.frame.remainder <= 0:
        if ws.frame.fin: # we're at the end of the message, break
          trace "Read all frames, breaking"
          ws.frame = nil
          break

        ws.frame = await ws.readFrame(ws.extensions)

        if not ws.updateReadMode:
          raise newException(WSOpcodeMismatchError, "Text/binary mode switch")

  except CatchableError as exc:
    trace "Exception reading frames", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()
    raise exc

  finally:
    if not isNil(ws.frame) and
      (ws.frame.fin and ws.frame.remainder <= 0):
      trace "Last frame in message and no more bytes left to read," &
        " reseting current frame"
      ws.frame = nil

  return consumed

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
    var buf = newSeq[byte](min(size, ws.frameSize))
    let read = await ws.recv(addr buf[0], buf.len)

    buf.setLen(read)
    if res.len + buf.len > size:
      raise newException(WSMaxMessageSizeError, "Max message size exceeded")

    trace "Read message", size = read
    res.add(buf)

    # no more frames
    if isNil(ws.frame):
      break

    # read the entire message, exit
    if ws.frame.fin and ws.frame.remainder <= 0:
      trace "Read full message, breaking!"
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
    trace "Exception closing", exc = exc.msg


proc recv2*(
    ws: WSSession,
    prequel: seq[byte],
    size = WSMaxMessageSize): Future[(seq[byte],seq[byte])] {.async.} =
  ## Low level utf8-aware read utility based and not unlike `recv()`. The
  ## function will return a bait of byte sequences
  ## ::
  ##    (vetted,remainder)
  ##
  ## where the full result is `vetted & remainder` with `vetted` being the
  ## validated prefix of the message and `remainder` some rest that could not
  ## be validated.
  ##
  ## For a binary message, this sequence pair collapses into the trivial case
  ## with the `remainder` always the empty sequence `@[]`.
  ##
  ## For utf8 messages, the `vetted` sequence contains complete utf8 encoded
  ## code points and the `remainder` something that is no code point. Typically,
  ## the `ramainder` would contain a partial code point broken up across the
  ## input read size boundary.
  ##
  ## There are only binary or utf8 massages supported but the scheme could be
  ## extended with an ameded RFC 6455 or a supersession.
  ##
  ## The argument `prequel` is is used to preload the input buffer. Subsequent
  ## message data is appended. So the full result `vetted & remainder` will
  ## have `prequel` as leading sub-sequence, i.e.
  ## ::
  ##    (vetted & remainder)[0 ..< prequel.len] == prequel
  ##
  ## The argument `size` limits the length of the returned sequence, i.e.
  ## ::
  ##    (vetted & remainder).len <= size
  ##
  ## The intended use of this low level function is to be able to code
  ## something for utf8 messages, and binaries alike:
  ## ::
  ##    var message, vetted, remainder: seq[byte]
  ##    while ws.readystate != ReadyState.Closed:
  ##      (vetted, remainder) = await ws.recv(prequel = remainder, size = 7)
  ##      message.add vetted
  ##      ...
  ##
  var
    res = prequel
    rdPos = prequel.len     # append position for buffer `res`

  # Preallocate buffer to be appended to after `prequel`
  res.setLen(rdPos + min(size, ws.frameSize))

  while ws.readyState != ReadyState.Closed:
    let read = await ws.recv(addr res[rdPos], res.len - rdPos)

    trace "Read message", size = read
    rdPos += read

    # Stop receiving if max size reached
    if size <= read:
      break

    # Stop if there are no more frames
    if ws.frame.isNil:
      break

    # Stop if entire message was received
    if ws.frame.fin and ws.frame.remainder <= 0:
      trace "Read full message, breaking!"
      break

  if ws.binary:
    # Trim buffer to the size used
    res.setLen(rdPos)
    return (res, @[])

  # Split buffer in utf8 validated part and some remainder
  let
    valid = res.toOpenArray(0, rdPos - 1).utf8Prequel
    tail = res[valid ..< rdPos]
  res.setLen(valid)

  return (res, tail)


proc recv2*(
    ws: WSSession,
    size = WSMaxMessageSize): Future[seq[byte]] {.async.} =
  ## This function is the equivalent of `recv()` with utf8 verification if
  ## applicable, It is fully equivalent to `recv()` for binaries.
  ##
  ##
  ##
  let (vetted, tail) = await ws.recv2(prequel = @[], size = size)

  if tail.len != 0:
    raise newException(WSInvalidUTF8, "Invalid UTF8 sequence detected")

  if ws.readyState != ReadyState.Closed:
    var c: byte
    if 0 < await ws.recv(addr c, 1):
      raise newException(WSMaxMessageSizeError, "Max message size exceeded")

  return vetted

# End
