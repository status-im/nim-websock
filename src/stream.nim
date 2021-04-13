import pkg/[chronos,
            chronos/apps/http/httpserver,
            chronos/timer,
            chronicles,
            httputils]
import strutils

const
  HttpHeadersTimeout = timer.seconds(120) # timeout for receiving headers (120 sec)
  HeaderSep = @[byte('\c'), byte('\L'), byte('\c'), byte('\L')]
  MaxHttpHeadersSize = 8192 # maximum size of HTTP headers in octets

proc readHeaders*(rstream: AsyncStreamReader): Future[seq[byte]] {.async.} =
  var buffer = newSeq[byte](MaxHttpHeadersSize)
  var error = false
  try:
    let hlenfut = rstream.readUntil(
      addr buffer[0], MaxHttpHeadersSize,
      sep = HeaderSep)
    let ores = await withTimeout(hlenfut, HttpHeadersTimeout)
    if not ores:
      # Timeout
      debug "Timeout expired while receiving headers",
            address = rstream.tsource.remoteAddress()
      error = true
    else:
      let hlen = hlenfut.read()
      buffer.setLen(hlen)
  except AsyncStreamLimitError:
    # size of headers exceeds `MaxHttpHeadersSize`
    debug "Maximum size of headers limit reached",
          address = rstream.tsource.remoteAddress()
    error = true
  except AsyncStreamIncompleteError:
    # remote peer disconnected
    debug "Remote peer disconnected", address = rstream.tsource.remoteAddress()
    error = true
  except AsyncStreamError as exc:
    debug "Problems with networking", address = rstream.tsource.remoteAddress(),
          error = exc.msg
    error = true

  if error:
    buffer.setLen(0)
  return buffer

proc closeWait*(wsStream: AsyncStream): Future[void] {.async.} =
  if not wsStream.writer.tsource.closed():
    await wsStream.writer.tsource.closeWait()
  if not wsStream.reader.tsource.closed():
    await wsStream.reader.tsource.closeWait()

# TODO: Implement stream read and write wrapper.
