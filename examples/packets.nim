import ../src/ws, nativesockets, chronos, os, chronicles

proc generateData(num: int64): seq[byte] =
  var str = newSeqOfCap[byte](num)
  for i in 0 ..< num:
    str.add(65)
  return str

let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8888), path = "/ws",
    protocols = @["myfancyprotocol"])
info "Websocket client: ", State = wsClient.readyState

var testString = generateData(2)
waitFor wsClient.send(testString)
var recvData = waitFor wsClient.receiveStrPacket()
assert recvData == testString
os.sleep(1000)

testString = generateData(1000000)
waitFor wsClient.send(testString)
recvData = waitFor wsClient.receiveStrPacket()
assert recvData == testString
os.sleep(1000)

testString = generateData(1)
waitFor wsClient.send(testString)
recvData = waitFor wsClient.receiveStrPacket()
assert recvData == testString
os.sleep(1000)
