import ws, nativesockets, chronos, os, chronicles

let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8888), path = "/ws",
    protocols = @["myfancyprotocol"])
info "Websocket client: ", State = wsClient.readyState

for idx in 1 .. 5:
  waitFor wsClient.send("Hello Server")
  let recvData = waitFor wsClient.receiveStrPacket()
  info "Server:", data = recvData
  os.sleep(1000)

