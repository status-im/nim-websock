import ../src/ws, nativesockets, chronos,chronicles, stew/byteutils

proc main() {.async.} =
  let ws = await WebSocket.connect(
    "127.0.0.1",
    Port(8888),
    path = "/ws")

  debug "Websocket client: ", State = ws.readyState

  let reqData = "Hello Server"
  while true:
    try:
      await ws.send(reqData)
      let buff = await ws.recv()
      if buff.len <= 0:
        break

      let dataStr = string.fromBytes(buff)
      debug "Server Response: ", data = dataStr

      assert dataStr == reqData
      break
    except WebSocketError as exc:
      error "WebSocket error:", exception = exc.msg

    await sleepAsync(100.millis)

  # close the websocket
  await ws.close()

waitFor(main())
