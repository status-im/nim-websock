## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import
  std/[strutils],
  pkg/[chronos, chronicles, stew/byteutils],
  ../websock/[websock, types, frame, extensions/compression/deflate]

const
  clientFlags = {NoVerifyHost, NoVerifyServerName}

# we want to run parallel tests in CI,
# so we are using different port
when defined tls:
  const
    agent      = "websock-secure-client"
    secure     = true
    serverPort = 9002
else:
  const
    agent      = "websock-client"
    secure     = false
    serverPort = 9001

proc connectServer(path: string, factories: seq[ExtFactory] = @[]): Future[WSSession] {.async.} =
  let ws = await WebSocket.connect(
    host = "127.0.0.1:$1" % [$serverPort],
    path = path,
    secure = secure,
    flags = clientFlags,
    factories = factories
  )
  return ws

proc getCaseCount(): Future[int] {.async.} =
  var caseCount = 0
  block:
    try:
      let ws = await connectServer("/getCaseCount")
      let buff = await ws.recvMsg()
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
    trace "request autobahn server to generate report"
    let ws = await connectServer("/updateReports?agent=" & agent)
    while true:
      let buff = await ws.recvMsg()
      if buff.len <= 0:
        break
    await ws.close()
  except WebSocketError as exc:
    error "WebSocket error", exception = exc.msg

proc main() {.async.} =
  let caseCount = await getCaseCount()
  trace "case count", count=caseCount

  var deflateFactory = @[deflateFactory()]
  for i in 1..caseCount:
    trace "runcase", no=i
    let path = "/runCase?case=$1&agent=$2" % [$i, agent]
    try:
      let ws = await connectServer(path, deflateFactory)

      while ws.readystate != ReadyState.Closed:
        # echo back
        let data = await ws.recvMsg()
        let opCode = if ws.binary:
                       Opcode.Binary
                     else:
                       Opcode.Text

        if ws.readyState == ReadyState.Closed:
          break

        await ws.send(data, opCode)

    except WebSocketError as exc:
      error "WebSocket error", exception = exc.msg

  await generateReport()

waitFor main()
