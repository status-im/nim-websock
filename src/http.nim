import chronos, chronos/timer, httputils, chronicles, uri, tables, strutils

const
  MaxHttpHeadersSize = 8192       # maximum size of HTTP headers in octets
  MaxHttpRequestSize = 128 * 1024 # maximum size of HTTP body in octets
  HttpHeadersTimeout = timer.seconds(120) # timeout for receiving headers (120 sec)
  CRLF* = "\r\n"
  HeaderSep = @[byte('\c'), byte('\L'), byte('\c'), byte('\L')]

type
  HttpClient* = ref object
    connected: bool
    currentURL: Uri      ## Where we are currently connected.
    headers: HttpHeaders ## Headers to send in requests.
    transp*: StreamTransport
    buf: seq[byte]

  HttpHeaders* = object
    table*: TableRef[string, seq[string]]

  ReqStatus = enum
    Success, Error, ErrorFailure

  AsyncCallback = proc (transp: StreamTransport,
      header: HttpRequestHeader): Future[void] {.closure, gcsafe.}
  HttpServer* = ref object of StreamServer
    callback: AsyncCallback

proc recvData(transp: StreamTransport): Future[seq[byte]] {.async.} =
  var buffer = newSeq[byte](MaxHttpHeadersSize)
  var error = false
  try:
    let hlenfut = transp.readUntil(addr buffer[0], MaxHttpHeadersSize,
        sep = HeaderSep)
    let ores = await withTimeout(hlenfut, HttpHeadersTimeout)
    if not ores:
      # Timeout
      debug "Timeout expired while receiving headers",
             address = transp.remoteAddress()
      error = true
    else:
      let hlen = hlenfut.read()
      buffer.setLen(hlen)
  except TransportLimitError:
    # size of headers exceeds `MaxHttpHeadersSize`
    debug "Maximum size of headers limit reached",
          address = transp.remoteAddress()
    error = true
  except TransportIncompleteError:
    # remote peer disconnected
    debug "Remote peer disconnected", address = transp.remoteAddress()
    error = true
  except TransportOsError as exc:
    debug "Problems with networking", address = transp.remoteAddress(),
          error = exc.msg
    error = true

  if error:
    buffer.setLen(0)
  return buffer

proc newConnection(client: HttpClient, url: Uri) {.async.} =
  if client.connected:
    return

  let port =
    if url.port == "": 80
    else: url.port.parseInt

  client.transp = await connect(initTAddress(url.hostname, port))

  # May be connected through proxy but remember actual URL being accessed
  client.currentURL = url
  client.connected = true

proc generateHeaders(requestUrl: Uri, httpMethod: string,
    additionalHeaders: HttpHeaders): string =
  # GET
  var headers = httpMethod.toUpperAscii()
  headers.add ' '

  if not requestUrl.path.startsWith("/"): headers.add '/'
  headers.add(requestUrl.path)

  # HTTP/1.1\c\l
  headers.add(" HTTP/1.1" & CRLF)

  for key, val in additionalHeaders.table:
    headers.add(key & ": " & val.join(", ") & CRLF)
  headers.add(CRLF)
  return headers

# Send request to the client. Currently only supports HTTP get method.
proc request*(client: HttpClient, url, httpMethod: string,
             body = "", headers: HttpHeaders): Future[seq[byte]]
             {.async.} =
  # Helper that actually makes the request. Does not handle redirects.
  let requestUrl = parseUri(url)
  if requestUrl.scheme == "":
    raise newException(ValueError, "No uri scheme supplied.")

  await newConnection(client, requestUrl)

  let headerString = generateHeaders(requestUrl, httpMethod, headers)
  let res = await client.transp.write(headerString)
  if res != len(headerString):
    raise newException(ValueError, "Error while send request to client")

  var value = await client.transp.recvData()
  if value.len == 0:
    raise newException(ValueError, "Empty response from server")
  return value

proc sendHTTPResponse*(transp: StreamTransport, version: HttpVersion, code: HttpCode,
                data: string = ""): Future[bool] {.async.} =
  var answer = $version
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

  let res = await transp.write(answer)
  if res == len(answer):
    return true
  raise newException(IOError, "Failed to send http request.")

proc validateRequest(transp: StreamTransport,
                     header: HttpRequestHeader): Future[ReqStatus] {.async.} =
  if header.meth notin {MethodGet}:
    debug "GET method is only allowed", address = transp.remoteAddress()
    if await transp.sendHTTPResponse(header.version, Http405):
      return Error
    else:
      return ErrorFailure

  var hlen = header.contentLength()
  if hlen < 0 or hlen > MaxHttpRequestSize:
    debug "Invalid header length", address = transp.remoteAddress()
    if await transp.sendHTTPResponse(header.version, Http413):
      return Error
    else:
      return ErrorFailure

  return Success

proc serveClient(server: StreamServer, transp: StreamTransport) {.async.} =
  ## Process transport data to the RPC server
  var httpServer = cast[HttpServer](server)
  var buffer = newSeq[byte](MaxHttpHeadersSize)
  var header: HttpRequestHeader

  info "Received connection", address = $transp.remoteAddress()
  try:
    let hlenfut = transp.readUntil(addr buffer[0], MaxHttpHeadersSize,
        sep = HeaderSep)
    let ores = await withTimeout(hlenfut, HttpHeadersTimeout)
    if not ores:
      # Timeout
      debug "Timeout expired while receiving headers",
            address = transp.remoteAddress()
      discard await transp.sendHTTPResponse(HttpVersion11, Http408)
      await transp.closeWait()
      return
    else:
      let hlen = hlenfut.read()
      buffer.setLen(hlen)
      header = buffer.parseRequest()
      if header.failed():
        # Header could not be parsed
        debug "Malformed header received",
              address = transp.remoteAddress()
        discard await transp.sendHTTPResponse(HttpVersion11, Http400)
        await transp.closeWait()
        return
      var vres = await validateRequest(transp, header)
      if vres == Success:
        info "Received valid RPC request", address = $transp.remoteAddress()
        # Call the user's callback.
        if httpServer.callback != nil:
          await httpServer.callback(transp, header)
      elif vres == ErrorFailure:
        debug "Remote peer disconnected", address = transp.remoteAddress()
  except TransportLimitError:
    # size of headers exceeds `MaxHttpHeadersSize`
    debug "Maximum size of headers limit reached",
          address = transp.remoteAddress()
    discard await transp.sendHTTPResponse(HttpVersion11, Http413)
  except TransportIncompleteError:
    # remote peer disconnected
    debug "Remote peer disconnected", address = transp.remoteAddress()
  except TransportOsError as exc:
    debug "Problems with networking", address = transp.remoteAddress(),
          error = exc.msg
  except CatchableError as exc:
    debug "Unknown exception", address = transp.remoteAddress(),
          error = exc.msg
  await transp.closeWait()

proc newHttpServer*(address: string, handler: AsyncCallback,
              flags: set[ServerFlags] = {ReuseAddr}): HttpServer =
  let address = initTAddress(address)
  var server = HttpServer(callback: handler)
  server = cast[HttpServer](createStreamServer(address, serveClient, flags,
      child = cast[StreamServer](server)))
  return server

func toCaseInsensitive*(headers: HttpHeaders, s: string): string {.inline.} =
  return toUpperAscii(s)

func newHttpHeaders*(): HttpHeaders =
  ## Returns a new ``HttpHeaders`` object. if ``titleCase`` is set to true,
  ## headers are passed to the server in title case (e.g. "Content-Length")
  return HttpHeaders(table: newTable[string, seq[string]]())

func newHttpHeaders*(keyValuePairs:
    openArray[tuple[key: string, val: string]]): HttpHeaders =
  ## Returns a new ``HttpHeaders`` object from an array. if ``titleCase`` is set to true,
  ## headers are passed to the server in title case (e.g. "Content-Length")
  var headers = newHttpHeaders()

  for pair in keyValuePairs:
    let key = headers.toCaseInsensitive(pair.key)
    if key in headers.table:
      headers.table[key].add(pair.val)
    else:
      headers.table[key] = @[pair.val]
  return headers

proc newHttpClient*(headers = newHttpHeaders()): HttpClient =
  return HttpClient(headers: headers)

proc close*(client: HttpClient) =
  ## Closes any connections held by the HTTP client.
  if client.connected:
    client.transp.close()
    client.connected = false
