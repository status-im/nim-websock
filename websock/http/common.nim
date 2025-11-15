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
  std/[uri],
  chronos,
  httputils,
  stew/byteutils,
  chronicles,
  chronos/apps/http/httptable,
  chronos/streams/tlsstream

export httputils, httptable, tlsstream, uri

logScope:
  topics = "websock http-common"

const
  MaxHttpHeadersSize* = 8192       # maximum size of HTTP headers in octets
  MaxHttpRequestSize* = 128 * 1024 # maximum size of HTTP body in octets
  HttpHeadersTimeout* = 120.seconds # timeout for receiving headers (120 sec)
  HttpErrorTimeout* = 2.seconds # How long we wait for error sending to complete
  HeaderSep* = @[byte('\c'), byte('\L'), byte('\c'), byte('\L')]
  CRLF* = "\r\n"

type
  ReqStatus* {.pure.} = enum
    Success, Error, ErrorFailure

  HttpCommon* = ref object of RootObj
    headers*: HttpTable
    code*: int
    version*: HttpVersion
    stream*: AsyncStream

  HttpRequest* = ref object of HttpCommon
    uri*: Uri
    meth*: HttpMethod

  # TODO: add useful response params, like body len
  HttpResponse* = ref object of HttpCommon
    reason*: string

  HttpError* = object of CatchableError
  HttpHeaderError* = HttpError

when not declared(newSeqUninit): # nim 2.2+
  template newSeqUninit[T: byte](len: int): seq[byte] =
    newSeqUninitialized[byte](len)

proc add(v: var seq[byte], data: string) =
  v.add data.toOpenArrayByte(0, data.high())

proc closeTransp*(transp: StreamTransport) {.async, deprecated.} =
  if not transp.closed():
    await transp.closeWait()

proc closeStream*(stream: AsyncStreamRW) {.async, deprecated.} =
  if not stream.closed():
    await stream.closeWait()

proc closeWait*(stream: AsyncStream) {.async: (raises: []).} =
  await noCancel allFutures(stream.reader.closeWait(), stream.writer.closeWait())
  await stream.reader.tsource.closeWait()

proc close*(stream: AsyncStream) =
  stream.reader.close()
  stream.writer.close()
  stream.reader.tsource.close()

proc readHttpHeader*(
    stream: AsyncStreamReader
): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
  var buffer = newSeqUninit[byte](MaxHttpHeadersSize)
  let hlen = await stream.readUntil(addr buffer[0], MaxHttpHeadersSize, sep = HeaderSep)
  buffer.setLen(hlen)
  buffer

func toHttpTable*(header: HttpRequestHeader | HttpResponseHeader): HttpTable =
  var res = HttpTable.init()
  for key, value in header.headers():
    res.add(key, value)
  res

proc sendResponse*(
    request: HttpRequest,
    code: HttpCode,
    headers: HttpTables = HttpTable.init(),
    data: openArray[byte] = @[],
    version = HttpVersion11,
    content = "",
) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  ## Send response
  ##

  var headers = headers
  var response = newSeqOfCap[byte](1024 + data.len)

  response.add($version)
  response.add(" ")
  response.add($code)
  response.add(CRLF)
  response.add("Date: " & httpDate() & CRLF)

  if data.len > 0:
    if headers.getInt("Content-Length").int != data.len:
      warn "Wrong content length header, overriding"
      headers.set("Content-Length", $data.len)

    if headers.getString("Content-Type") != content:
      headers.set("Content-Type",
        if content.len > 0: content else: "text/html")

  for key, val in headers.stringItems(true):
    response.add(key)
    response.add(": ")
    response.add(val)
    response.add(CRLF)

  response.add(CRLF)
  response.add(data)

  request.stream.writer.write(response)

proc sendResponse*(
    request: HttpRequest,
    code: HttpCode,
    headers: HttpTables = HttpTable.init(),
    data: string,
    version = HttpVersion11,
    content = "",
): Future[void] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  request.sendResponse(
    code, headers, data.toOpenArrayByte(0, data.high()), version, content
  )

proc sendError*(
    stream: AsyncStreamWriter, code: HttpCode, version = HttpVersion11
) {.async: (raises: [CancelledError]).} =
  var response = newSeqOfCap[byte](1024)
  response.add($version)
  response.add(" ")
  response.add($code)
  response.add(CRLF)
  response.add(CRLF)
  response.add($code)

  try:
    # When sending errors, don't waste too much time on it..
    discard await stream.write(response).withTimeout(HttpErrorTimeout)
  except AsyncStreamError:
    # Ignore errors while sending error responses to not swallow the original
    # error that caused us to want to send an error
    discard

proc sendError*(
    request: HttpRequest, code: HttpCode, version = HttpVersion11
): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  request.stream.writer.sendError(code, version)
