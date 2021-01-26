import ../src/ws, nativesockets, chronos, os, chronicles, stew/byteutils

let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8888), path = "/ws",
    protocols = @["myfancyprotocol"])
info "Websocket client: ", State = wsClient.readyState

let reqData = "Hello Server"
for idx in 1 .. 5:
  try:
    waitFor wsClient.sendStr(reqData)
    let recvData = waitFor wsClient.receiveStrPacket()
    let dataStr = string.fromBytes(recvData)
    info "Server:", data = dataStr
    assert dataStr == reqData
  except WebSocketError:
    error "WebSocket error:", exception = getCurrentExceptionMsg()
  os.sleep(1000)

# Gracefully close the websocket
wsClient.close()

