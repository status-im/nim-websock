packageName = "ws"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "WS protocol implementation"
license = "MIT"
skipDirs = @["examples", "tests"]

requires "nim == 1.2.6"
requires "chronos >= 2.5.2"
requires "httputils >= 0.2.0"
requires "chronicles >= 0.10.0"
requires "urlly >= 0.2.0"
requires "stew >= 0.1.0"
requires "asynctest >= 0.2.0 & < 0.3.0"
requires "nimcrypto"

task test, "run tests":
  exec "nim c -r --opt:speed -d:debug --verbosity:0 --hints:off ./tests/testall.nim"
  rmFile "./tests/testall"
  rmFile "./tests/testframes"
  rmFile "./tests/testwebsockets"
