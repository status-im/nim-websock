# Websocket for Nim

![Github action](https://github.com/status-im/nim-ws/workflows/nim-ws%20CI/badge.svg)

We're working towards an implementation of the
[Websocket](https://tools.ietf.org/html/rfc6455) protocol for
[Nim](https://nim-lang.org/). This is very much a work in progress, and not yet
in a usable state.

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
- [ ] UTF-8 Handling
- [x] Close Handling
  - [x] Basic close behavior
  - [x] Close frame structure
   - [x] Payload length
   - [x] Valid close codes
   - [x] Invalid close codes
- [ ] Integrate Autobahn Test suite. (In progress)
- [ ] WebSocket Compression
- [ ] WebSocket Extensions
- [ ] Performance
