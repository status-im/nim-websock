import
  std/[strutils],
  pkg/[chronos, chronicles, stew/byteutils],
  ../ws/[ws, types, frame]

const
  clientFlags = {NoVerifyHost, NoVerifyServerName}

const agent = when defined tls:
                "nim-ws-tls-client"
              else:
                "nim-ws-client"
const secure = defined tls

proc connectServer(path: string): Future[WSSession] {.async.} =
  let ws = await WebSocket.connect(
    host = "127.0.0.1",
    port = Port(9001),
    path = path,
    secure=secure,
    flags=clientFlags
  )
  return ws

proc getCaseCount(): Future[int] {.async.} =
  var caseCount = 0
  block:
    try:
      let ws = await connectServer("/getCaseCount")
      let buff = await ws.recv()
      let dataStr = string.fromBytes(buff)
      caseCount = parseInt(dataStr)
      await ws.close()
      break
    except WebSocketError as exc:
      error "WebSocket error", exception = exc.msg
    except ValueError as exc:
      error "ParseInt error", exception = exc.msg

  return caseCount

proc generateReport() {.async.} =
  try:
    let ws = await connectServer("/updateReports?agent=" & agent)
    while true:
      let buff = await ws.recv()
      if buff.len <= 0:
        break
    await ws.close()
  except WebSocketError as exc:
    error "WebSocket error", exception = exc.msg

proc main() {.async.} =
  let caseCount = await getCaseCount()
  trace "case count", count=caseCount

  for i in 1..caseCount:
    let path = "/runCase?case=$1&agent=$2" % [$i, agent]
    try:
      let ws = await connectServer(path)
      # echo back
      let data = await ws.recv()
      let opCode = if ws.binary:
                     Opcode.Binary
                   else:
                     Opcode.Text
      await ws.send(data, opCode)
      await ws.close()
    except WebSocketError as exc:
      error "WebSocket error", exception = exc.msg

  await generateReport()

waitFor main()
