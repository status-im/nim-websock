import ../src/ws, ../src/http, nativesockets, chronos, os, chronicles, stew/byteutils

let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8888), path = "/ws",
    protocols = @["myfancyprotocol"])
info "Websocket client: ", State = wsClient.readyState

for idx in 1 .. 5:
  try:
    waitFor wsClient.sendStr("Hello Server")
    let recvData = waitFor wsClient.receiveStrPacket()
    info "Server:", data = string.fromBytes(recvData)
  except WebSocketError:
    error "WebSocket error:", exception = getCurrentExceptionMsg()
  os.sleep(1000)

# Gracefully close the websocket
wsClient.close()

