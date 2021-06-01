import pkg/[chronos,
            chronos/streams/tlsstream,
            chronicles,
            stew/byteutils]

import ../ws/ws

proc main() {.async.} =
    let ws = await WebSocket.tlsConnect(
        "127.0.0.1",
        Port(8888),
        path = "/wss",
        protocols = @["myfancyprotocol"],
        flags = {NoVerifyHost, NoVerifyServerName})
    debug "Websocket client: ", State = ws.readyState

    let reqData = "Hello Server"
    try:
        debug "sending client "
        await ws.send(reqData)
        let buff = await ws.recv()
        if buff.len <= 0:
            break
        let dataStr = string.fromBytes(buff)
        debug "Server:", data = dataStr

        assert dataStr == reqData
        return # bail out
    except WebSocketError as exc:
        error "WebSocket error:", exception = exc.msg

    # close the websocket
    await ws.close()

waitFor(main())
