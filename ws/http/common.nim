{.push raises: [Defect].}

import std/[uri]
import pkg/[
  chronos,
  httputils,
  stew/byteutils,
  chronicles]

import pkg/[
  chronos/apps/http/httptable,
  chronos/streams/tlsstream]

export httputils, httptable, tlsstream, uri

const
  MaxHttpHeadersSize* = 8192       # maximum size of HTTP headers in octets
  MaxHttpRequestSize* = 128 * 1024 # maximum size of HTTP body in octets
  HttpHeadersTimeout* = 120.seconds # timeout for receiving headers (120 sec)
  HeaderSep* = @[byte('\c'), byte('\L'), byte('\c'), byte('\L')]
  CRLF* = "\r\n"

type
  ReqStatus* {.pure.} = enum
    Success, Error, ErrorFailure

  HttpRequest* = ref object of RootObj
    headers*: HttpTable
    uri*: Uri
    meth*: HttpMethod
    code*: int
    version*: HttpVersion
    stream*: AsyncStream

  # TODO: add useful response params, like body len
  HttpResponse* = ref object of RootObj
    headers*: HttpTable
    code*: int
    reason*: string
    version*: HttpVersion
    stream*: AsyncStream

  HttpError* = object of CatchableError
  HttpHeaderError* = HttpError

proc closeWait*(stream: AsyncStream) {.async.} =
  # TODO: this is most likelly wrong
  await allFutures(
    stream.writer.tsource.closeWait(),
    stream.reader.tsource.closeWait())

  await allFutures(
    stream.writer.closeWait(),
    stream.reader.closeWait())

proc sendResponse*(
  request: HttpRequest,
  code: HttpCode,
  headers: HttpTables = HttpTable.init(),
  data: seq[byte] = @[],
  version = HttpVersion11,
  content = "") {.async.} =
  ## Send response
  ##

  var headers = headers
  var response: string = $version
  response.add(" ")
  response.add($code)
  response.add(CRLF)
  response.add("Date: " & httpDate() & CRLF)

  if data.len > 0:
    if headers.getInt("Content-Length").int != data.len:
      debug "Wrong content length header, overriding"
      headers.set("Content-Length", $data.len)

    if headers.getString("Content-Type") != content:
      headers.set("Content-Type",
        if content.len > 0: content else: "text/html")

  for key, value in headers.stringItems(true):
    response.add(key.normalizeHeaderName())
    response.add(": ")
    response.add(value)
    response.add(CRLF)

  response.add(CRLF)
  await request.stream.writer.write(
    response.toBytes() & data)

proc sendResponse*(
  request: HttpRequest,
  code: HttpCode,
  headers: HttpTables = HttpTable.init(),
  data: string,
  version = HttpVersion11,
  content = ""): Future[void] =
  request.sendResponse(code, headers, data.toBytes(), version, content)

proc sendError*(
  stream: AsyncStreamWriter,
  code: HttpCode,
  version = HttpVersion11) {.async.} =
  let content = $code
  var response: string = $version
  response.add(" ")
  response.add(content & CRLF)
  response.add(CRLF)

  await stream.write(
    response.toBytes() &
    content.toBytes())
