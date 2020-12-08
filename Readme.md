# Websocket for Nim

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
