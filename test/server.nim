import ws, chronos, chronicles, httputils

proc cb(transp: StreamTransport, header: HttpRequestHeader) {.async.} =
  info "Header: ", header
  let res = await transp.sendHTTPResponse(HttpVersion11, Http200, "Hello World")
  debug "Disconnecting client", address = transp.remoteAddress()
  await transp.closeWait()

when isMainModule:
  let address = "127.0.0.1:8888"
  var httpServer = newHttpServer(address, cb)
  httpServer.start()
  waitFor httpServer.join()
