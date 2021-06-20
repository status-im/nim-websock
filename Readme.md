# Websocket for Nim

![Github action](https://github.com/status-im/nim-ws/workflows/nim-ws%20CI/badge.svg)

This is an implementation of [Websocket](https://tools.ietf.org/html/rfc6455) protocol for
[Nim](https://nim-lang.org/). nim-ws have both client and server in regular ws and wss(secure) mode.

It also pass all autobahn tests [Autobahn summary report](https://status-im.github.io/nim-ws/).

 Building and testing
--------------------

Install dependencies:

```bash
nimble install -d
```

Starting HTTP server:

```bash
nim c -r test/server.nim
```

Testing Server Response:

```bash
curl --location --request GET 'http://localhost:8888'
```

Testing Websocket Handshake:
```bash
curl --include \
   --no-buffer \
   --header "Connection: Upgrade" \
   --header "Upgrade: websocket" \
   --header "Host: example.com:80" \
   --header "Origin: http://example.com:80" \
   --header "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
   --header "Sec-WebSocket-Version: 13" \
   http://localhost:8888/ws
```

## Roadmap

- [x] Framing
  - [x] Text Messages
  - [x] Binary Messages
- [x] Pings/Pongs
- [x] Reserved Bits
- [x] Opcodes
  - [x] Non-control Opcodes
  - [x] Control Opcodes
- [x] Fragmentation
- [x] UTF-8 Handling
- [x] Close Handling
  - [x] Basic close behavior
  - [x] Close frame structure
   - [x] Payload length
   - [x] Valid close codes
   - [x] Invalid close codes
- [x] Integrate Autobahn Test suite.
- [x] WebSocket Compression
- [x] WebSocket Extensions
- [ ] Performance
