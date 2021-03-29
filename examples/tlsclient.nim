import pkg/[chronos, 
            chronos/streams/tlsstream,
            chronicles,     
            stew/byteutils]  

import ../src/ws
 
proc main() {.async.} =
    let ws = await webSocketTLSConnect(
        "127.0.0.1",
        Port(8888),
        path = "/wss",
        protocols = @["myfancyprotocol"],
        flags = {NoVerifyHost,NoVerifyServerName})
    
    debug "Websocket TLS client: ", State = ws.readyState

    let reqData = "Hello Server"
    try:
        await ws.send(reqData)
        let buff = await ws.recv()
        if buff.len <= 0:
            break
    
        # buff.setLen(read) # truncate buffer to size of read data
        let dataStr = string.fromBytes(buff)
        debug "Server Response:", data = dataStr
    
        assert dataStr == reqData
        return # bail out
    except WebSocketError as exc:
        error "WebSocket error:", exception = exc.msg
    
    # close the websocket
    await ws.close()
waitFor(main())