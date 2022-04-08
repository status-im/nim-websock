## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/uri
import pkg/[
  chronos,
  chronicles,
  httputils]

when isLogFormatUsed(json):
  import json_serialization/std/net

import ./common

logScope:
  topics = "websock http-server"

type
  HttpAsyncCallback* = proc (request: HttpRequest):
    Future[void] {.closure, gcsafe, raises: [Defect].}

  HttpServer* = ref object of StreamServer
    handler*: HttpAsyncCallback
    handshakeTimeout*: Duration
    headersTimeout*: Duration
    case secure*: bool:
    of true:
      tlsFlags*: set[TLSFlags]
      tlsPrivateKey*: TLSPrivateKey
      tlsCertificate*: TLSCertificate
      minVersion*: TLSVersion
      maxVersion*: TLSVersion
    else:
      discard

  TlsHttpServer* = HttpServer

proc validateRequest(
  stream: AsyncStreamWriter,
  header: HttpRequestHeader): Future[ReqStatus] {.async.} =
  ## Validate Request
  ##

  if header.meth notin {MethodGet}:
    trace "GET method is only allowed", address = stream.tsource.remoteAddress()
    await stream.sendError(Http405, version = header.version)
    return ReqStatus.Error

  var hlen = header.contentLength()
  if hlen < 0 or hlen > MaxHttpRequestSize:
    trace "Invalid header length", address = stream.tsource.remoteAddress()
    await stream.sendError(Http413, version = header.version)
    return ReqStatus.Error

  return ReqStatus.Success

proc parseRequest(
  server: HttpServer,
  stream: AsyncStream): Future[HttpRequest] {.async.} =
  ## Process transport data to the HTTP server
  ##

  var buffer = newSeq[byte](MaxHttpHeadersSize)
  let remoteAddr = stream.reader.tsource.remoteAddress()
  trace "Received connection", address = $remoteAddr
  try:
    let hlenfut = stream.reader.readUntil(
      addr buffer[0], MaxHttpHeadersSize, sep = HeaderSep)
    let ores = await withTimeout(hlenfut, server.headersTimeout)
    if not ores:
      # Timeout
      trace "Timeout expired while receiving headers", address = $remoteAddr
      await stream.writer.sendError(Http408, version = HttpVersion11)
      raise newException(HttpError, "Didn't read headers in time!")

    let hlen = hlenfut.read()
    buffer.setLen(hlen)
    let requestData = buffer.parseRequest()
    if requestData.failed():
      # Header could not be parsed
      trace "Malformed header received", address = $remoteAddr
      await stream.writer.sendError(Http400, version = HttpVersion11)
      raise newException(HttpError, "Malformed header received")

    var vres = await stream.writer.validateRequest(requestData)
    let hdrs =
      block:
        var res = HttpTable.init()
        for key, value in requestData.headers():
          res.add(key, value)
        res

    if vres == ReqStatus.ErrorFailure:
      trace "Remote peer disconnected", address = $remoteAddr
      raise newException(HttpError, "Remote peer disconnected")

    trace "Received valid HTTP request", address = $remoteAddr
    return HttpRequest(
        headers: hdrs,
        stream: stream,
        uri: requestData.uri().parseUri())
  except TransportLimitError:
    # size of headers exceeds `MaxHttpHeadersSize`
    trace "maximum size of headers limit reached", address = $remoteAddr
    await stream.writer.sendError(Http413, version = HttpVersion11)
  except TransportIncompleteError:
    # remote peer disconnected
    trace "Remote peer disconnected", address = $remoteAddr
  except TransportOsError as exc:
    trace "Problems with networking", address = $remoteAddr, error = exc.msg

proc handleConnCb(
  server: StreamServer,
  transp: StreamTransport) {.async.} =
  var stream: AsyncStream
  try:
    stream = AsyncStream(
      reader: newAsyncStreamReader(transp),
      writer: newAsyncStreamWriter(transp))

    let httpServer = HttpServer(server)
    let request = await httpServer.parseRequest(stream)

    await httpServer.handler(request)
  except CatchableError as exc:
    debug "Exception in HttpHandler", exc = exc.msg
  finally:
    await stream.closeWait()

proc handleTlsConnCb(
  server: StreamServer,
  transp: StreamTransport) {.async.} =

  let tlsHttpServer = TlsHttpServer(server)
  let tlsStream = newTLSServerAsyncStream(
    newAsyncStreamReader(transp),
    newAsyncStreamWriter(transp),
    tlsHttpServer.tlsPrivateKey,
    tlsHttpServer.tlsCertificate,
    minVersion = tlsHttpServer.minVersion,
    maxVersion = tlsHttpServer.maxVersion,
    flags = tlsHttpServer.tlsFlags)

  let stream = AsyncStream(
      reader: tlsStream.reader,
      writer: tlsStream.writer)
  try:
    let httpServer = HttpServer(server)
    let request = await httpServer.parseRequest(stream)

    await httpServer.handler(request)
  except CatchableError as exc:
    debug "Exception in HttpHandler", exc = exc.msg
  finally:
    await stream.closeWait()

proc accept*(server: HttpServer): Future[HttpRequest] {.async.} =
  if not isNil(server.handler):
    raise newException(HttpError,
      "Callback already registered - cannot mix callback and accepts styles!")

  trace "Awaiting new request"
  let transp = await StreamServer(server).accept()
  let stream = if server.secure:
    let tlsStream = newTLSServerAsyncStream(
      newAsyncStreamReader(transp),
      newAsyncStreamWriter(transp),
      server.tlsPrivateKey,
      server.tlsCertificate,
      minVersion = server.minVersion,
      maxVersion = server.maxVersion,
      flags = server.tlsFlags)

    AsyncStream(
      reader: tlsStream.reader,
      writer: tlsStream.writer)
  else:
    AsyncStream(
      reader: newAsyncStreamReader(transp),
      writer: newAsyncStreamWriter(transp))

  trace "Got new request", isTls = server.secure
  try:
    let
      parseFut = server.parseRequest(stream)
    if await withTimeout(parseFut, server.handshakeTimeout):
      return parseFut.read()
    raise newException(HttpError, "Timed out parsing request")
  except CatchableError as exc:
    # Can't hold up the accept loop
    stream.close()
    raise exc


proc create*(
  _: typedesc[HttpServer],
  address: TransportAddress | string,
  handler: HttpAsyncCallback = nil,
  flags: set[ServerFlags] = {},
  headersTimeout = HttpHeadersTimeout,
  handshakeTimeout = 0.seconds
  ): HttpServer
  {.raises: [Defect, CatchableError].} = # TODO: remove CatchableError
  ## Make a new HTTP Server
  ##

  var server = HttpServer(
    handler: handler,
    headersTimeout: headersTimeout,
    handshakeTimeout:
      if handshakeTimeout == 0.seconds:
        # default to headersTimeout * 1.05
        headersTimeout + (headersTimeout div 20)
      else: handshakeTimeout,
  )

  let localAddress =
    when address is string:
      initTAddress(address)
    else:
      address

  server = HttpServer(
    createStreamServer(
      localAddress,
      handleConnCb,
      flags,
      child = StreamServer(server)))

  trace "Created HTTP Server", host = $server.localAddress()

  return server

proc create*(
  _: typedesc[TlsHttpServer],
  address: TransportAddress | string,
  tlsPrivateKey: TLSPrivateKey,
  tlsCertificate: TLSCertificate,
  handler: HttpAsyncCallback = nil,
  flags: set[ServerFlags] = {},
  tlsFlags: set[TLSFlags] = {},
  tlsMinVersion = TLSVersion.TLS12,
  tlsMaxVersion = TLSVersion.TLS12,
  headersTimeout = HttpHeadersTimeout,
  handshakeTimeout = 0.seconds
  ): TlsHttpServer
  {.raises: [Defect, CatchableError].} = # TODO: remove CatchableError

  var server = TlsHttpServer(
    headersTimeout: headersTimeout,
    handshakeTimeout:
      if handshakeTimeout == 0.seconds:
        # default to headersTimeout * 1.05
        headersTimeout + (headersTimeout div 20)
      else: handshakeTimeout,
    secure: true,
    handler: handler,
    tlsPrivateKey: tlsPrivateKey,
    tlsCertificate: tlsCertificate,
    minVersion: tlsMinVersion,
    maxVersion: tlsMaxVersion)

  let localAddress =
    when address is string:
      initTAddress(address)
    else:
      address

  server = TlsHttpServer(
    createStreamServer(
      localAddress,
      handleTlsConnCb,
      flags,
      child = StreamServer(server)))

  trace "Created TLS HTTP Server", host = $server.localAddress()

  return server
