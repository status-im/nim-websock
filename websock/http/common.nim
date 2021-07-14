## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

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

logScope:
  topics = "websock http-common"

const
  MaxHttpHeadersSize* = 8192       # maximum size of HTTP headers in octets
  MaxHttpRequestSize* = 128 * 1024 # maximum size of HTTP body in octets
  HttpHeadersTimeout* = 120.seconds # timeout for receiving headers (120 sec)
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

proc closeTransp*(transp: StreamTransport) {.async.} =
  if not transp.closed():
    await transp.closeWait()

proc closeStream*(stream: AsyncStreamRW) {.async.} =
  if not stream.closed():
    await stream.closeWait()

proc closeWait*(stream: AsyncStream) {.async.} =
  await allFutures(
    stream.reader.closeStream(),
    stream.writer.closeStream(),
    stream.reader.tsource.closeTransp())

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
    response.toBytes() & content.toBytes())

proc sendError*(
  request: HttpRequest,
  code: HttpCode,
  version = HttpVersion11): Future[void] =
  request.stream.writer.sendError(code, version)
