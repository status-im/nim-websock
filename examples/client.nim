import ../src/ws, nativesockets, chronos, os, chronicles, stew/byteutils

proc main() {.async.} =
  let ws = await connect(
    "127.0.0.1", Port(8888),
    path = "/ws",
    protocols = @["myfancyprotocol"])

  info "Websocket client: ", State = ws.readyState

  let reqData = "Hello Server"
  while true:
    try:
      await ws.send(reqData)
      var buff = newSeq[byte](100)
      let read = await ws.recv(addr buff[0], buff.len)
      if read <= 0:
        break

      buff.setLen(read) # truncate buffer to size of read data
      let dataStr = string.fromBytes(buff)
      info "Server:", data = dataStr

      assert dataStr == reqData
      return # bail out
    except WebSocketError as exc:
      error "WebSocket error:", exception = exc.msg

    await sleepAsync(100.millis)

  # close the websocket
  await ws.close()

waitFor(main())
