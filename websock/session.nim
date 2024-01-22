## nim-websock
## Copyright (c) 2021-2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push gcsafe, raises: [].}

import std/strformat
import pkg/[chronos, chronicles, stew/byteutils, stew/endians2]
import ./types, ./frame, ./utf8dfa, ./http

import pkg/chronos/streams/asyncstream

logScope:
  topics = "websock ws-session"

template used(x: typed) =
  # silence unused warning
  discard

proc prepareCloseBody(code: StatusCodes, reason: string): seq[byte] =
  result = reason.toBytes
  if ord(code) > 999:
    result = @(ord(code).uint16.toBytesBE()) & result

proc writeMessage(ws: WSSession,
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
  while ws.readyState notin {ReadyState.Closing, ReadyState.Closed}:
    let canSend = min(data.len - i, maxSize)
    let frame = Frame(
        fin: if (canSend + i >= data.len): true else: false,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: if i > 0: Opcode.Cont else: opcode, # fragments have to be `Continuation` frames
        mask: ws.masked,
        data: data[i ..< canSend + i],
        maskKey: maskKey)

    let encoded = await frame.encode(extensions)
    await ws.stream.writer.write(encoded)

    i += canSend
    if i >= data.len:
      break

proc writeControl(
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

func isControl(opcode: Opcode): bool =
  opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}

proc nonCancellableSend(
  ws: WSSession,
  data: seq[byte] = @[],
  opcode: Opcode): Future[void]
  {.async.} =
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

  let maskKey =
    if ws.masked:
      MaskKey.random(ws.rng[])
    else:
      default(MaskKey)

  if opcode.isControl:
    await ws.writeControl(data, opcode, maskKey)
  else:
    await ws.writeMessage(data, opcode, maskKey, ws.extensions)

proc doSend(
  ws: WSSession,
  data: seq[byte] = @[],
  opcode: Opcode
  ): Future[void] =
  let
    retFut = newFuture[void]("doSend")
    sendFut = ws.nonCancellableSend(data, opcode)

  proc handleSend {.async.} =
    try:
      await sendFut
      retFut.complete()
    except CatchableError as exc:
      retFut.fail(exc)

  asyncSpawn handleSend()
  retFut

proc sendLoop(ws: WSSession) {.gcsafe, async.} =
  while ws.sendQueue.len > 0:
    let task = ws.sendQueue.popFirst()
    if task.fut.cancelled:
      continue

    try:
      await ws.doSend(task.data, task.opcode)
      task.fut.complete()
    except CatchableError as exc:
      task.fut.fail(exc)

proc send*(
  ws: WSSession,
  data: seq[byte] = @[],
  opcode: Opcode): Future[void] =
  if opcode.isControl:
    # Control frames (see Section 5.5) MAY be injected in the middle of
    # a fragmented message.  Control frames themselves MUST NOT be
    # fragmented.
    # See RFC 6455 Section 5.4 Fragmentation
    return ws.doSend(data, opcode)

  let fut = newFuture[void]("send")

  ws.sendQueue.addLast (data: data, opcode: opcode, fut: fut)

  if isNil(ws.sendLoop) or ws.sendLoop.finished:
    ws.sendLoop = sendLoop(ws)

  fut

proc send*(
  ws: WSSession,
  data: string): Future[void] =
  send(ws, data.toBytes(), Opcode.Text)

proc handleClose*(
  ws: WSSession,
  frame: Frame,
  payload: seq[byte] = @[]) {.async.} =
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
      code = StatusCodes(uint16.fromBytesBE(payload[0..<2]))
    except RangeDefect:
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
    reason = string.fromBytes(payload[2..payload.high])

    if not ws.binary and validateUTF8(reason) == false:
      raise newException(WSInvalidUTF8,
        "Invalid UTF8 sequence detected in close reason")

  trace "Handling close message", code = ord(code), reason
  if not isNil(ws.onClose):
    try:
      (code, reason) = ws.onClose(code, reason)
    except CatchableError as exc:
      used(exc)
      trace "Exception in Close callback, this is most likely a bug", exc = exc.msg
  else:
    code = StatusFulfilled
    reason = ""

  # don't respond to a terminated connection
  if ws.readyState != ReadyState.Closing:
    ws.readyState = ReadyState.Closing
    trace "Sending close", code = ord(code), reason
    try:
      await ws.send(prepareCloseBody(code, reason), Opcode.Close).wait(5.seconds)
    except CatchableError as exc:
      used(exc)
      trace "Failed to send Close opcode", err=exc.msg

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

  var payload = newSeq[byte](frame.length.int)
  if frame.length > 0:
    payload.setLen(frame.length.int)
    # Read control frame payload.
    await ws.stream.reader.readExactly(addr payload[0], frame.length.int)
    if frame.mask:
      mask(
        payload.toOpenArray(0, payload.high),
        frame.maskKey)

  # Process control frame payload.
  case frame.opcode:
  of Opcode.Ping:
    if not isNil(ws.onPing):
      try:
        ws.onPing(payload)
      except CatchableError as exc:
        used(exc)
        trace "Exception in Ping callback, this is most likely a bug", exc = exc.msg

    # send pong to remote
    await ws.send(payload, Opcode.Pong)
  of Opcode.Pong:
    if not isNil(ws.onPong):
      try:
        ws.onPong(payload)
      except CatchableError as exc:
        used(exc)
        trace "Exception in Pong callback, this is most likely a bug", exc = exc.msg
  of Opcode.Close:
    await ws.handleClose(frame, payload)
  else:
    raise newException(WSInvalidOpcodeError, "Invalid control opcode!")

{.warning[HoleEnumConv]:off.}

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

{.warning[HoleEnumConv]:on.}

proc ping*(
  ws: WSSession,
  data: seq[byte] = @[]): Future[void] =
  ws.send(data, opcode = Opcode.Ping)

proc recv*(
  ws: WSSession,
  data: pointer | ptr byte | ref seq[byte], # nim bug: pointer doesn't match ptr byte?
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
  ## Use this to stream data from frames
  ##

  doAssert ws.reading == false, "Only one concurrent read allowed"
  ws.reading = true
  defer: ws.reading = false

  var consumed = 0
  when data is pointer or data is ptr byte:
    let pbuffer = cast[ptr UncheckedArray[byte]](data)
  try:
    if isNil(ws.frame):
      ws.frame = await ws.readFrame(ws.extensions)
      ws.first = true

    while consumed < size:
      if isNil(ws.frame):
        assert ws.readyState == ReadyState.Closed
        trace "Closed connection, breaking"
        break

      logScope:
        first = ws.first
        fin = ws.frame.fin
        len = ws.frame.length
        consumed = ws.frame.consumed
        remainder = ws.frame.remainder
        opcode = ws.frame.opcode
        masked = ws.frame.mask

      if ws.first == (ws.frame.opcode == Opcode.Cont):
        error "Opcode mismatch!"
        raise newException(WSOpcodeMismatchError,
          &"Opcode mismatch: first: {ws.first}, opcode: {ws.frame.opcode}")

      if ws.first:
        ws.binary = ws.frame.opcode == Opcode.Binary # set binary flag
        trace "Setting binary flag"

      let len = min(ws.frame.remainder.int, size - consumed)
      if len > 0:
        trace "Reading bytes from frame stream", len
        when data is ref seq[byte]:
          data[].setLen(consumed + len)
          let read = await ws.frame.read(ws.stream.reader, addr data[][consumed], len)
        else:
          let read = await ws.frame.read(ws.stream.reader, addr pbuffer[consumed], len)
        if read <= 0:
          trace "Didn't read any bytes, stopping"
          raise newException(WSClosedError, "WebSocket is closed!")

        trace "Read data from frame", read
        consumed += read

      # all has been consumed from the frame
      # read the next frame
      if ws.frame.remainder <= 0:
        ws.first = false

        if ws.frame.fin: # we're at the end of the message, break
          trace "Read all frames, breaking"
          ws.frame = nil
          break

        # read next frame
        ws.frame = await ws.readFrame(ws.extensions)
  except CatchableError as exc:
    trace "Exception reading frames", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()

    raise exc
  finally:
    if not isNil(ws.frame) and
      (ws.frame.fin and ws.frame.remainder <= 0):
      trace "Last frame in message and no more bytes left to read, reseting current frame"
      ws.frame = nil

  return consumed

proc recvMsg*(
  ws: WSSession,
  size = WSMaxMessageSize): Future[seq[byte]] {.async.} =
  ## Attempt to read a full message up to max `size`
  ## bytes in `frameSize` chunks.
  ##
  ## If no `fin` flag arrives await until cancelled or
  ## closed.
  ##
  ## If message is larger than `size` a `WSMaxMessageSizeError`
  ## exception is thrown.
  ##
  ## In all other cases it awaits a full message.
  ##
  try:
    var res: seq[byte]
    while ws.readyState != ReadyState.Closed:
      var buf = new(seq[byte])
      let read {.used.} = await ws.recv(buf, min(size, ws.frameSize))

      if res.len + buf[].len > size:
        raise newException(WSMaxMessageSizeError, "Max message size exceeded")

      trace "Read message", size = read
      res.add(buf[])

      # no more frames
      if isNil(ws.frame):
        break

      # read the entire message, exit
      if ws.frame.fin and ws.frame.remainder <= 0:
        trace "Read full message, breaking!"
        break

    if ws.readyState == ReadyState.Closed:
      # avoid reporting incomplete message
      raise newException(WSClosedError, "WebSocket is closed!")

    if not ws.binary and validateUTF8(res.toOpenArray(0, res.high)) == false:
      raise newException(WSInvalidUTF8, "Invalid UTF8 sequence detected")

    return res
  except CatchableError as exc:
    trace "Exception reading message", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.stream.closeWait()

    raise exc

proc recv*(
  ws: WSSession,
  size = WSMaxMessageSize): Future[seq[byte]]
  {.deprecated: "deprecated in favor of recvMsg()".} =
  ws.recvMsg(size)

proc close*(
  ws: WSSession,
  code = StatusFulfilled,
  reason: string = "") {.async.} =
  ## Close the Socket, sends close packet.
  ##

  if ws.readyState != ReadyState.Open:
    return

  proc gentleCloser(ws: WSSession, closeBody: seq[byte]) {.async.} =
    await ws.send(
      closeBody,
      opcode = Opcode.Close)

    # read frames until closed
    try:
      while ws.readyState != ReadyState.Closed:
        discard await ws.readFrame()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      discard exc # most likely EOF
  try:
    ws.readyState = ReadyState.Closing
    await gentleCloser(ws, prepareCloseBody(code, reason)).wait(10.seconds)
  except CancelledError as exc:
    trace "Cancellation when closing!", exc = exc.msg
    raise exc
  except CatchableError as exc:
    used(exc)
    trace "Exception closing", exc = exc.msg
  finally:
    await ws.stream.closeWait()
    ws.readyState = ReadyState.Closed
