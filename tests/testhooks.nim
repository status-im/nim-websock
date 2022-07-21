## nim-websock
## Copyright (c) 2021-2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/[
  httputils,
  chronos/unittest2/asynctests,
  ]

import ../websock/websock

import ./helpers

let address = initTAddress("127.0.0.1:8888")

type
  TokenHook* = ref object of Hook
    status: int
    token: string
    request: HttpRequest

proc clientAppendGoodToken(ctx: Hook, headers: var HttpTable):
     Result[void, string] {.gcsafe, raises: [Defect].} =
  headers.add("auth-token", "good-token")
  return ok()

proc clientAppendBadToken(ctx: Hook, headers: var HttpTable):
     Result[void, string] {.gcsafe, raises: [Defect].} =
  headers.add("auth-token", "bad-token")
  return ok()

proc clientVerify(ctx: Hook, headers: HttpTable):
     Future[Result[void, string]] {.async, gcsafe, raises: [Defect].} =
  var p = TokenHook(ctx)
  p.token = headers.getString("auth-status")
  return ok()

proc serverVerify(ctx: Hook, headers: HttpTable):
     Future[Result[void, string]] {.async, gcsafe, raises: [Defect].} =
  var p = TokenHook(ctx)
  if headers.getString("auth-token") == "good-token":
    p.status = 101
  return ok()

proc serverAppend(ctx: Hook, headers: var HttpTable):
     Result[void, string] {.gcsafe, raises: [Defect].} =
  var p = TokenHook(ctx)
  if p.status == 101:
    headers.add("auth-status", "accept")
  else:
    headers.add("auth-status", "reject")
  p.status = 0
  return ok()

proc goodClientHook(): Hook =
  TokenHook(
    append: clientAppendGoodToken,
    verify: clientVerify
  )

proc badClientHook(): Hook =
  TokenHook(
    append: clientAppendBadToken,
    verify: clientVerify
  )

proc serverHook(): Hook =
  TokenHook(
    append: serverAppend,
    verify: serverVerify
  )

proc serverVerifyWithCode(ctx: Hook, headers: HttpTable):
     Future[Result[void, string]] {.async, gcsafe, raises: [Defect].} =
  var p = TokenHook(ctx)
  if headers.getString("auth-token") == "good-token":
    p.status = 101
    return ok()
  else:
    await p.request.stream.writer.sendError(Http401)
    return err("authentication error")

proc serverHookWithCode(request: HttpRequest): Hook =
  TokenHook(
    append: serverAppend,
    verify: serverVerifyWithCode,
    request: request
  )

suite "Test Hooks":
  setup:
    var
      server: HttpServer
      goodCP = goodClientHook()
      badCP  = badClientHook()

  teardown:
    if server != nil:
      server.stop()
      waitFor server.closeWait()

  asyncTest "client with valid token":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let
        server = WSServer.new()
        ws = await server.handleRequest(
          request,
          hooks = @[serverHook()]
        )

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await WebSocket.connect(
      host = initTAddress("127.0.0.1:8888"),
      path = WSPath,
      hooks = @[goodCP]
    )

    check TokenHook(goodCP).token == "accept"
    await session.stream.closeWait()

  asyncTest "client with bad token":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let
        server = WSServer.new()
        ws = await server.handleRequest(
          request,
          hooks = @[serverHook()]
        )

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await WebSocket.connect(
      host = initTAddress("127.0.0.1:8888"),
      path = WSPath,
      hooks = @[badCP]
    )

    check TokenHook(badCP).token == "reject"
    await session.stream.closeWait()

  asyncTest "server hook with code get good client":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let
        server = WSServer.new()
        ws = await server.handleRequest(
          request,
          hooks = @[serverHookWithCode(request)]
        )

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    let session = await WebSocket.connect(
      host = initTAddress("127.0.0.1:8888"),
      path = WSPath,
      hooks = @[goodCP]
    )

    check TokenHook(goodCP).token == "accept"
    await session.stream.closeWait()

  asyncTest "server hook with code get bad client":
    proc handle(request: HttpRequest) {.async.} =
      check request.uri.path == WSPath
      let
        server = WSServer.new()
        ws = await server.handleRequest(
          request,
          hooks = @[serverHookWithCode(request)]
        )

    server = createServer(
      address = address,
      handler = handle,
      flags = {ReuseAddr})

    expect WSFailedUpgradeError:
      let session = await WebSocket.connect(
        host = initTAddress("127.0.0.1:8888"),
        path = WSPath,
        hooks = @[badCP]
      )
      await session.stream.closeWait()
