import ws, chronos

when isMainModule:
  let address = "127.0.0.1:8888"
  var httpServer = newHttpServer(address)
  httpServer.server.start()
  waitFor httpServer.server.join()
