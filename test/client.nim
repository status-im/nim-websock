import ws, nativesockets, chronos

discard waitFor newAsyncWebsocketClient("localhost", Port(8080), path = "/", protocols = @["myfancyprotocol"])
echo "connected"

runForever()

