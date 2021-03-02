import helpers, unittest, ../src/http, chronos, ../src/ws,../src/random,
    stew/byteutils, os, strutils

var httpServer: HttpServer
proc startServer() {.async.} =
  httpServer = newHttpServer("127.0.0.1:8888", cb)
  httpServer.start()

proc closeServer() {.async.} =
  httpServer.stop()
  waitFor httpServer.closeWait()

suite "Test web socket communication":

  setup:
    waitFor startServer()
    let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8888),
            path = "/ws", protocols = @["myfancyprotocol"])

  teardown:
     waitFor closeServer()

  test "Websocket conversation between client and server":
    waitFor sendRecvClientData(wsClient, "Hello Server")

  test "Test for small message ":
    let msg = string.fromBytes(generateData(100))
    waitFor sendRecvClientData(wsClient, msg)

  test "Test for medium message ":
    let msg = string.fromBytes(generateData(1000))
    waitFor sendRecvClientData(wsClient, msg)

  test "Test for large message ":
    let msg = string.fromBytes(generateData(1000000))
    waitFor sendRecvClientData(wsClient, msg)


suite "Test websocket error cases":
    teardown:
        httpServer.stop()
        waitFor httpServer.closeWait()

    test "Test for incorrect protocol":
        httpServer = newHttpServer("127.0.0.1:8888", incorrectProtocolCB)
        httpServer.start()
        try:
            let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8888),
                    path = "/ws", protocols = @["mywrongprotocol"])
        except WebSocketError:
            require contains(getCurrentExceptionMsg(), "Server did not reply with a websocket upgrade")

    test "Test for incorrect port":
        httpServer = newHttpServer("127.0.0.1:8888", cb)
        httpServer.start()
        try:
            let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8889),
                    path = "/ws", protocols = @["myfancyprotocol"])
        except:
            require contains(getCurrentExceptionMsg(), "Connection refused")

    test "Test for incorrect path":
        httpServer = newHttpServer("127.0.0.1:8888", cb)
        httpServer.start()
        try:
            let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8888),
                    path = "/gg", protocols = @["myfancyprotocol"])
        except:
          require contains(getCurrentExceptionMsg(), "Server did not reply with a websocket upgrade")

suite "Misc Test":
    setup:
        waitFor startServer()
    teardown:
      waitFor closeServer()

    test "Test for maskKey":
      let wsClient = waitFor newWebsocketClient("127.0.0.1", Port(8888), path = "/ws",
                protocols = @["myfancyprotocol"])
      let maskKey = genMaskKey(wsClient.rng)
      require maskKey.len == 4

    test "Test for toCaseInsensitive":
      let headers = newHttpHeaders()
      require toCaseInsensitive(headers, "webSocket") == "Websocket"
