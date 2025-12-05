## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import chronos, chronicles, httputils, ./common

when isLogFormatUsed(json):
  import json_serialization/std/net as jsnet
  export jsnet

logScope:
  topics = "websock http-server"

type
  HttpAsyncCallback* = proc(request: HttpRequest) {.async.}

  HttpServer* = ref object of StreamServer
    handler*: HttpAsyncCallback
    headersTimeout*: Duration
    case secure*: bool
    of true:
      tlsFlags*: set[TLSFlags]
      tlsPrivateKey*: TLSPrivateKey
      tlsCertificate*: TLSCertificate
      minVersion*: TLSVersion
      maxVersion*: TLSVersion
    else:
      discard

  TlsHttpServer* {.deprecated.} = HttpServer

template used(x: typed) =
  # silence unused warning
  discard

proc readHttpRequest(
    stream: AsyncStream, headersTimeout: Duration
): Future[HttpRequest] {.
    async: (raises: [CancelledError, AsyncStreamError, HttpError])
.} =
  ## Process transport data to the HTTP server
  ##
  when chronicles.enabledLogLevel == LogLevel.TRACE:
    let remoteAddr =
      stream.reader.tsource.remoteAddress2().valueOr(default(TransportAddress))

  trace "Received connection", remoteAddr

  let
    requestData =
      try:
        await stream.reader.readHttpHeader().wait(headersTimeout)
      except AsyncTimeoutError:
        trace "Timeout expired while receiving headers", remoteAddr
        await stream.writer.sendError(Http408, version = HttpVersion11)
        raise newException(HttpError, "Didn't read headers in time!")

    request = requestData.parseRequest()

  if request.failed():
    # Header could not be parsed
    trace "Malformed header received", remoteAddr
    await stream.writer.sendError(Http400, version = HttpVersion11)
    raise newException(HttpError, "Malformed header received")

  if request.meth != MethodGet:
    trace "GET method is only allowed", remoteAddr
    await stream.writer.sendError(Http405, version = request.version)
    raise newException(HttpError, $Http405)

  let hlen = request.contentLength()
  if hlen < 0 or hlen > MaxHttpRequestSize:
    trace "Invalid header length", remoteAddr
    await stream.writer.sendError(Http413, version = request.version)
    raise newException(HttpError, $Http413)

  trace "Received valid HTTP request", address = $remoteAddr
  HttpRequest(
    headers: request.toHttpTable(), stream: stream, uri: request.uri().parseUri()
  )

proc processHttpRequest*(
  server: HttpServer, stream: AsyncStream
): Future[HttpRequest] {.
    async: (raises: [CancelledError, AsyncStreamError, HttpError])
.} =
  return await readHttpRequest(stream, server.headersTimeout)

proc openAsyncStream(
    server: HttpServer, transp: StreamTransport
): Result[AsyncStream, string] =
  if server.secure:
    try:
      let tlsStream = newTLSServerAsyncStream(
        newAsyncStreamReader(transp),
        newAsyncStreamWriter(transp),
        server.tlsPrivateKey,
        server.tlsCertificate,
        minVersion = server.minVersion,
        maxVersion = server.maxVersion,
        flags = server.tlsFlags,
      )

      ok AsyncStream(reader: tlsStream.reader, writer: tlsStream.writer)
    except CatchableError as exc:
      err exc.msg
  else:
    ok AsyncStream(
      reader: newAsyncStreamReader(transp), writer: newAsyncStreamWriter(transp)
    )

proc handleConnCb(
    server: StreamServer, transp: StreamTransport
) {.async: (raises: []).} =
  let
    server = HttpServer(server)
    stream = server.openAsyncStream(transp).valueOr:
      debug "Failed to open streams", err = error
      await transp.closeWait()
      return

  try:
    let request = await stream.readHttpRequest(server.headersTimeout)

    await server.handler(request)
  except CatchableError as exc:
    used(exc)
    debug "Exception in HttpHandler", exc = exc.msg
  finally:
    await stream.closeWait()

proc acceptStream*(server: HttpServer): Future[AsyncStream] {.async.} =
  if not isNil(server.handler):
    raise newException(
      HttpError, "Callback already registered - cannot mix callback and accepts styles!"
    )

  trace "Awaiting new request"
  let
    transp = await StreamServer(server).accept()
    stream = server.openAsyncStream(transp).valueOr:
      await transp.closeWait()
      raise (ref HttpError)(msg: error)

  trace "Got new request", isTls = server.secure
  return stream

# TODO async raises not implemented for accept because it breaks libp2p (1.13.0
#      at the time of writing)
proc accept*(server: HttpServer): Future[HttpRequest] {.async.} =
  let stream = await acceptStream(server)

  try:
    await stream.readHttpRequest(server.headersTimeout)
  except CancelledError as exc:
    await stream.closeWait()
    raise exc
  except AsyncStreamError as exc:
    await stream.closeWait()
    raise exc
  except HttpError as exc:
    await stream.closeWait()
    raise exc

proc create*(
    _: typedesc[HttpServer],
    address: TransportAddress | string,
    handler: HttpAsyncCallback = nil,
    flags: set[ServerFlags] = {},
    headersTimeout = HttpHeadersTimeout,
): HttpServer {.raises: [TransportOsError].} =
  ## Make a new HTTP Server
  ##

  let localAddress =
    when address is string:
      initTAddress(address)
    else:
      address

  var server = HttpServer(handler: handler, headersTimeout: headersTimeout)

  server = HttpServer(
    createStreamServer(localAddress, handleConnCb, flags, child = StreamServer(server))
  )

  trace "Created HTTP Server", host = $server.localAddress()

  server

proc create*(
    _: typedesc[HttpServer],
    address: TransportAddress | string,
    handler: HttpAsyncCallback = nil,
    flags: set[ServerFlags] = {},
    headersTimeout = HttpHeadersTimeout,
    handshakeTimeout: Duration,
): HttpServer {.
    raises: [TransportOsError],
    deprecated: "Use headersTimeout instead of handshakeTimeout"
.} =
  let headersTimeout =
    if handshakeTimeout > 0.seconds:
      min(handshakeTimeout, headersTimeout)
    else:
      headersTimeout
  HttpServer.create(address, handler, flags, headersTimeout)

proc create*(
    _: typedesc[HttpServer],
    address: TransportAddress | string,
    tlsPrivateKey: TLSPrivateKey,
    tlsCertificate: TLSCertificate,
    handler: HttpAsyncCallback = nil,
    flags: set[ServerFlags] = {},
    tlsFlags: set[TLSFlags] = {},
    tlsMinVersion = TLSVersion.TLS12,
    tlsMaxVersion = TLSVersion.TLS12,
    headersTimeout = HttpHeadersTimeout,
): HttpServer {.raises: [TransportOsError].} =
  var server = HttpServer(
    headersTimeout: headersTimeout,
    secure: true,
    handler: handler,
    tlsPrivateKey: tlsPrivateKey,
    tlsCertificate: tlsCertificate,
    minVersion: tlsMinVersion,
    maxVersion: tlsMaxVersion,
  )

  let localAddress =
    when address is string:
      initTAddress(address)
    else:
      address

  server = HttpServer(
    createStreamServer(localAddress, handleConnCb, flags, child = StreamServer(server))
  )

  trace "Created TLS HTTP Server", host = $server.localAddress()

  server

proc create*(
    _: typedesc[HttpServer],
    address: TransportAddress | string,
    tlsPrivateKey: TLSPrivateKey,
    tlsCertificate: TLSCertificate,
    handler: HttpAsyncCallback = nil,
    flags: set[ServerFlags] = {},
    tlsFlags: set[TLSFlags] = {},
    tlsMinVersion = TLSVersion.TLS12,
    tlsMaxVersion = TLSVersion.TLS12,
    headersTimeout = HttpHeadersTimeout,
    handshakeTimeout: Duration,
): HttpServer {.
    raises: [TransportOsError],
    deprecated: "Use headersTimeout instead of handshakeTimeout"
.} =
  let headersTimeout =
    if handshakeTimeout > 0.seconds:
      min(handshakeTimeout, headersTimeout)
    else:
      headersTimeout

  HttpServer.create(
    address, tlsPrivateKey, tlsCertificate, handler, flags, tlsFlags, tlsMinVersion,
    tlsMaxVersion, headersTimeout,
  )

proc handshakeTimeout*(s: HttpServer): Duration {.deprecated: "headersTimeout".} =
  s.headersTimeout

proc `handshakeTimeout=`*(s: HttpServer, v: Duration) {.deprecated: "headersTimeout".} =
  s.headersTimeout = v
