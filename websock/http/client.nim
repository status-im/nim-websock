## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/[uri, strutils], chronos, chronicles, httputils, stew/byteutils, ./common

logScope:
  topics = "websock http-client"

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

proc closeWait*(client: HttpClient): Future[void] {.async: (raises: [], raw: true).} =
  client.stream.closeWait()

proc close*(client: HttpClient): Future[void] {.deprecated: "closeWait".} =
  client.closeWait()

proc generateHeaders(
  requestUrl: Uri,
  httpMethod: HttpMethod,
  version: HttpVersion,
  headers: HttpTables): string =
  var headersData = toUpperAscii($httpMethod)
  headersData.add " "

  if not requestUrl.path.startsWith("/"): headersData.add "/"
  headersData.add(requestUrl.path)
  if requestUrl.query.len > 0:
    headersData.add("?" & requestUrl.query)
  headersData.add(" ")
  headersData.add($version & CRLF)

  for (key, val) in headers.stringItems(true):
    headersData.add(key)
    headersData.add(": ")
    headersData.add(val)
    headersData.add(CRLF)

  headersData.add(CRLF)
  return headersData

proc request*(
    client: HttpClient,
    url: string | Uri,
    httpMethod = MethodGet,
    headers: HttpTables,
): Future[HttpResponse] {.
    async: (raises: [CancelledError, AsyncStreamError, HttpError])
.} =
  ## Helper that actually makes the request.
  ## Does not handle redirects.
  ##

  if not client.connected:
    raise newException(HttpError, "No connection to host!")

  let requestUrl =
    when url is string:
      url.parseUri()
    else:
      url

  let headerString = generateHeaders(requestUrl, httpMethod, client.version, headers)
  await client.stream.writer.write(headerString)

  let
    header =
      try:
        await client.stream.reader.readHttpHeader().wait(HttpHeadersTimeout)
      except AsyncTimeoutError:
        raise newException(HttpError, "Timeout expired while receiving headers")
    response = header.parseResponse()

  return HttpResponse(
    headers: response.toHttpTable(),
    stream: client.stream,
    code: response.code,
    reason: response.reason())

proc connect*(
    T: typedesc[HttpClient | TlsHttpClient],
    address: TransportAddress,
    version = HttpVersion11,
    tlsFlags: set[TLSFlags] = {},
    tlsMinVersion = TLSVersion.TLS12,
    tlsMaxVersion = TLSVersion.TLS12,
    hostName = "",
): Future[T] {.async: (raises: [CancelledError, AsyncStreamError, TransportError]).} =

  let transp = await connect(address)
  let client = T(
    hostname: address.host,
    port: address.port,
    address: transp.remoteAddress(),
    version: version)

  var stream = AsyncStream(
    reader: newAsyncStreamReader(transp),
    writer: newAsyncStreamWriter(transp))

  when T is TlsHttpClient:
    client.tlsFlags = tlsFlags
    client.minVersion = tlsMinVersion
    client.maxVersion = tlsMaxVersion

    let tlsStream = newTLSClientAsyncStream(
      stream.reader,
      stream.writer,
      serverName = hostName,
      minVersion = tlsMinVersion,
      maxVersion = tlsMaxVersion,
      flags = tlsFlags)

    stream = AsyncStream(
      reader: tlsStream.reader,
      writer: tlsStream.writer)

  client.stream = stream
  client.connected = true

  return client

proc connect*(
    T: typedesc[HttpClient | TlsHttpClient],
    host: string,
    version = HttpVersion11,
    tlsFlags: set[TLSFlags] = {},
    tlsMinVersion = TLSVersion.TLS12,
    tlsMaxVersion = TLSVersion.TLS12,
    hostName = "",
): Future[T] {.
    async: (raises: [CancelledError, AsyncStreamError, HttpError, TransportError])
.} =
  let wantedHostName = if hostName.len > 0:
      hostName
    else:
      host.split(":")[0]

  let addrs = resolveTAddress(host)
  var lastException: ref TransportError
  for a in addrs:
    try:
      let conn = await T.connect(
        a,
        version,
        tlsFlags,
        tlsMinVersion,
        tlsMaxVersion,
        hostName = wantedHostName)

      return conn
    except TransportError as exc:
      trace "Error connecting to address", address = $a, exc = exc.msg
      lastException = exc

  if lastException != nil:
    raise lastException

  raise newException(HttpError,
    "Unable to connect to host on any address!")
