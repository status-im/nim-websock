{.push raises: [Defect].}

import std/uri
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
  HttpClient* = ref object of RootObj
    connected*: bool
    hostname*: string
    address*: TransportAddress
    version*: HttpVersion
    port*: Port
    stream*: AsyncStream
    buf*: seq[byte]

  TlsHttpClient* = ref object of HttpClient
    tlsFlags*: set[TLSFlags]
    minVersion*: TLSVersion
    maxVersion*: TLSVersion

  ReqStatus* {.pure.} = enum
    Success, Error, ErrorFailure

  HttpRequest* = ref object of RootObj
    headers*: HttpTable
    uri*: Uri
    meth*: HttpMethod
    code*: HttpCode
    version*: HttpVersion
    stream*: AsyncStream

  # TODO: add useful response params, like body len
  HttpResponse* = ref object of RootObj
    headers*: HttpTable
    code*: HttpCode
    reason*: string
    version*: HttpVersion
    stream*: AsyncStream

  HttpAsyncCallback* = proc (request: HttpRequest):
    Future[void] {.closure, gcsafe, raises: [Defect].}

  HttpServer* = ref object of StreamServer
    callback*: HttpAsyncCallback

  TlsHttpServer* = ref object of HttpServer
    tlsFlags*: set[TLSFlags]
    tlsPrivateKey*: TLSPrivateKey
    tlsCertificate*: TLSCertificate
    minVersion*: TLSVersion
    maxVersion*: TLSVersion

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

proc sendHTTPResponse*(
  stream: AsyncStreamWriter,
  code: HttpCode,
  data: string = "",
  version = HttpVersion11) {.async.} =
  ## Send request
  ##

  var answer: string = $version
  answer.add(" ")
  answer.add($code)
  answer.add(CRLF)
  answer.add("Date: " & httpDate() & CRLF)
  if len(data) > 0:
    answer.add("Content-Type: application/json" & CRLF)
  answer.add("Content-Length: " & $len(data) & CRLF)
  answer.add(CRLF)
  if len(data) > 0:
    answer.add(data)

  await stream.write(answer.toBytes())

