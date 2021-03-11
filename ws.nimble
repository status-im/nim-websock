packageName = "ws"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "WS protocol implementation"
license = "MIT"

requires "nim == 1.2.6"
requires "chronos >= 2.5.2"
requires "httputils >= 0.2.0"
requires "chronicles >= 0.10.0"
requires "urlly >= 0.2.0"
requires "stew >= 0.1.0"
requires "eth"
requires "asynctest >= 0.2.0 & < 0.3.0"
requires "nimcrypto"

task lint, "format source files according to the official style guide":
  exec "./lint.nims"
