## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[strutils, random]
import pkg/[
  chronos,
  chronos/streams/tlsstream,
  httputils,
  chronicles,
  stew/byteutils]

import ../websock/websock
import ./keys

let
  WSSecureKey* = TLSPrivateKey.init(SecureKey)
  WSSecureCert* = TLSCertificate.init(SecureCert)

const WSPath* = when defined secure: "/wss" else: "/ws"

proc rndStr*(size: int): string =
  for _ in 0..<size:
    add(result, char(rand(int('A') .. int('z'))))

proc rndBin*(size: int): seq[byte] =
   for _ in 0..<size:
      add(result, byte(rand(0 .. 255)))

proc waitForClose*(ws: WSSession) {.async.} =
  try:
    while ws.readystate != ReadyState.Closed:
      discard await ws.recvMsg()
  except CatchableError:
    trace "Closing websocket"

proc createServer*(
  address = initTAddress("127.0.0.1:8888"),
  tlsPrivateKey = WSSecureKey,
  tlsCertificate = WSSecureCert,
  handler: HttpAsyncCallback = nil,
  flags: set[ServerFlags] = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr},
  tlsFlags: set[TLSFlags] = {},
  tlsMinVersion = TLSVersion.TLS12,
  tlsMaxVersion = TLSVersion.TLS12): HttpServer
  {.raises: [Defect, HttpError].} =
  try:
    let server = when defined secure:
      TlsHttpServer.create(
        address = address,
        tlsPrivateKey = tlsPrivateKey,
        tlsCertificate = tlsCertificate,
        flags = flags,
        tlsFlags = tlsFlags,
        tlsMinVersion = tlsMinVersion,
        tlsMaxVersion = tlsMaxVersion)
    else:
      HttpServer.create(
        address = address,
        flags = flags)

    when defined accepts:
      proc accepts() {.async, raises: [Defect].} =
        try:
          let req = await server.accept()
          await req.handler()
        except TransportOsError as exc:
          error "Transport error", exc = exc.msg

      asyncCheck accepts()
    else:
      server.handler = handler
      server.start()

    return server
  except CatchableError as exc:
    raise newException(Defect, exc.msg)

proc connectClient*(
  address = initTAddress("127.0.0.1:8888"),
  path = WSPath,
  protocols: seq[string] = @["proto"],
  flags: set[TLSFlags] = {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName},
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil,
  onClose: CloseCb = nil,
  rng: Rng = nil): Future[WSSession] {.async.} =
  let secure = when defined secure: true else: false
  return await WebSocket.connect(
    host = address,
    flags = flags,
    path = path,
    secure = secure,
    protocols = protocols,
    version = version,
    frameSize = frameSize,
    onPing = onPing,
    onPong = onPong,
    onClose = onClose,
    rng = rng)
