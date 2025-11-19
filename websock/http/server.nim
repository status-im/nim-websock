## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import chronos, chronicles, httputils, results, ./common

when isLogFormatUsed(json):
  import json_serialization/std/net as jsnet
  export jsnet

logScope:
  topics = "websock http-server"

const DefaultMaxConcurrentHandshakes = 100

type
  HttpAsyncCallback* = proc(request: HttpRequest) {.async.}

  HandshakeResult* = Result[HttpRequest, ref CatchableError]

  HttpServer* = ref object of StreamServer
    handler*: HttpAsyncCallback
    handshakeTimeout*: Duration
    headersTimeout*: Duration
    maxConcurrentHandshakes: int
    handshakeResults: AsyncQueue[HandshakeResult]
    handshakeDispatcher: Future[void]
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

  AcceptDispatcherFinishedError = object of CatchableError

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

# TODO async raises not implemented for accept because it breaks libp2p (1.13.0
#      at the time of writing)
proc accept*(server: HttpServer): Future[HttpRequest] {.async.} =
  if not isNil(server.handler):
    raise newException(
      HttpError, "Callback already registered - cannot mix callback and accepts styles!"
    )

  if server.closed:
    raise newException(TransportUseClosedError, "Server is closed")

  if isNil(server.handshakeDispatcher):
    let dispatcher = proc() {.async: (raises: []).} =
      trace "Starting background accept dispatcher"
      var activeHandshakes = 0
      let slotAvailable = newAsyncEvent()
      slotAvailable.fire()
      while not server.closed:
        try:
          if server.maxConcurrentHandshakes > 0 and
              activeHandshakes >= server.maxConcurrentHandshakes:
            slotAvailable.clear()
            await slotAvailable.wait()

          let transp = await StreamServer(server).accept()

          inc(activeHandshakes)

          let worker = proc(tsp: StreamTransport) {.async: (raises: []).} =
            defer:
              dec(activeHandshakes)
              slotAvailable.fire()

            let stream = server.openAsyncStream(tsp).valueOr:
              trace "Closed accepted socket (stream creation failed)", error = error
              await tsp.closeWait()
              try:
                server.handshakeResults.addLastNoWait(
                  HandshakeResult.err(newException(HttpError, error))
                )
              except AsyncQueueFullError:
                discard
              return

            try:
              let req = await stream.readHttpRequest(server.headersTimeout)
              try:
                server.handshakeResults.addLastNoWait(HandshakeResult.ok(req))
              except AsyncQueueFullError:
                discard
            except CatchableError as exc:
              trace "Closed accepted stream (request parsing failed)", exc = exc.msg
              await stream.closeWait()
              try:
                server.handshakeResults.addLastNoWait(HandshakeResult.err(exc))
              except AsyncQueueFullError:
                discard

          asyncSpawn worker(transp)
        except CatchableError as exc:
          if server.closed:
            return
          trace "Socket accept failed", exc = exc.msg
          try:
            await sleepAsync(100.milliseconds) # for temp failures such as FD exhaustion
          except CancelledError:
            continue
      try:
        server.handshakeResults.addLastNoWait(
          HandshakeResult.err(
            newException(AcceptDispatcherFinishedError, "Server is closed")
          )
        )
      except AsyncQueueFullError:
        error "server closed but accept dispatcher cannot wake up pending accept()s"

    server.handshakeDispatcher = dispatcher()

  let res = await server.handshakeResults.popFirst()

  if res.isErr:
    let err = res.error
    if err of AcceptDispatcherFinishedError:
      server.handshakeResults.addLastNoWait(res)
      raise newException(TransportUseClosedError, "Server is closed")
    raise err

  return res.value

proc create*(
    _: typedesc[HttpServer],
    address: TransportAddress | string,
    handler: HttpAsyncCallback = nil,
    flags: set[ServerFlags] = {},
    headersTimeout = HttpHeadersTimeout,
    handshakeTimeout = 0.seconds,
    maxConcurrentHandshakes = DefaultMaxConcurrentHandshakes,
): HttpServer {.raises: [TransportOsError].} =
  ## Make a new HTTP Server
  ##

  let localAddress =
    when address is string:
      initTAddress(address)
    else:
      address

  var server = HttpServer(
    # Workaround for clients that set handshakeTimeout instead of headersTimeout
    headersTimeout:
      if handshakeTimeout > 0.seconds:
        min(handshakeTimeout, headersTimeout)
      else:
        headersTimeout,
    maxConcurrentHandshakes: maxConcurrentHandshakes,
    handler: handler,
    handshakeResults: newAsyncQueue[HandshakeResult](),
  )

  server = HttpServer(
    createStreamServer(localAddress, handleConnCb, flags, child = StreamServer(server))
  )

  trace "Created HTTP Server", host = $server.localAddress()

  return server

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
    handshakeTimeout = 0.seconds,
    maxConcurrentHandshakes = DefaultMaxConcurrentHandshakes,
): HttpServer {.raises: [TransportOsError].} =
  # TODO handshakeTimeout is unused, remove eventually
  var server = HttpServer(
    # Workaround for clients that set handshakeTimeout instead of headersTimeout
    headersTimeout:
      if handshakeTimeout > 0.seconds:
        min(handshakeTimeout, headersTimeout)
      else:
        headersTimeout,
    maxConcurrentHandshakes: maxConcurrentHandshakes,
    secure: true,
    handler: handler,
    tlsPrivateKey: tlsPrivateKey,
    tlsCertificate: tlsCertificate,
    minVersion: tlsMinVersion,
    maxVersion: tlsMaxVersion,
    handshakeResults: newAsyncQueue[HandshakeResult](),
  )

  let localAddress =
    when address is string:
      initTAddress(address)
    else:
      address

  server = HttpServer(
    createStreamServer(
      localAddress, handleConnCb, flags, child = StreamServer(server)
    )
  )

  trace "Created TLS HTTP Server", host = $server.localAddress()

  return server
