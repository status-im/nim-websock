import
  std/[strutils],
  pkg/[chronos, chronicles, stew/byteutils],
  ../ws/[ws, types, frame]

type
  Arg = object
    host: string
    port: Port
    path: string

proc getCaseCount(arg: Arg): Future[int] {.async.} =
  let path = arg.path & "/getCaseCount"

  var caseCount = 0
  block:
    try:
      let ws = await WebSocket.connect(arg.host, arg.port, path)

      let buff = await ws.recv()
      if buff.len <= 0:
        break

      let dataStr = string.fromBytes(buff)
      caseCount = parseInt(dataStr)

      await ws.close()
      break

    except WebSocketError as exc:
      error "WebSocket error", exception = exc.msg
    except ValueError as exc:
      error "ParseInt error", exception = exc.msg

  return caseCount

proc generateReport(arg: Arg) {.async.} =
  let path = arg.path & "/updateReports?agent=nim-ws"
  try:
    let ws = await WebSocket.connect(arg.host, arg.port, path)

    while true:
      let buff = await ws.recv()
      if buff.len <= 0:
        break

    await ws.close()

  except WebSocketError as exc:
    error "WebSocket error", exception = exc.msg

proc main() {.async.} =
  let arg = Arg(host: "127.0.0.1", port: Port(9001))
  let caseCount = await getCaseCount(arg)
  notice "case count", count=caseCount

  for i in 1..caseCount:
    let path = "$1/runCase?case=$2&agent=nim-ws" % [arg.path, $i]
    try:
      let ws = await WebSocket.connect(arg.host, arg.port, path)

      # echo back
      while true:
        let data = await ws.recv()
        if data.len <= 0:
          break

        await ws.send(data, if ws.binary: Opcode.Binary else: Opcode.Text)

      await ws.close()
    except WebSocketError as exc:
      error "WebSocket error", exception = exc.msg

  await generateReport(arg)

waitFor main()
