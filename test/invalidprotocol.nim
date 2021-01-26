import ../src/ws, nativesockets, chronos, os, chronicles

var
    hadFailedNewSocket = false
block:
  try:
    let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8888), path = "/ws",
        protocols = @["myfancyprotocol2"])
    info "Websocket client: ", State = wsClient.readyState
    waitFor wsClient.sendStr("Hello Server")
    wsClient.close()
  except:
    error "WebSocket error:", exception = getCurrentExceptionMsg()
    hadFailedNewSocket = true
assert hadFailedNewSocket
