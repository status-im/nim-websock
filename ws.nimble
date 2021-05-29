packageName = "ws"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "WS protocol implementation"
license = "MIT"
skipDirs = @["examples", "test"]

requires "nim >= 1.2.6"
requires "chronos >= 3.0.0"
requires "httputils >= 0.2.0"
requires "chronicles >= 0.10.0"
requires "stew >= 0.1.0"
requires "asynctest >= 0.2.0 & < 0.3.0"
requires "nimcrypto"
requires "bearssl"

task test, "run tests":
  exec "nim c -r --opt:speed -d:debug --verbosity:0 --hints:off -d:chronicles_log_level=info ./tests/testcommon.nim"
  rmFile "./tests/testcommon"

  exec "nim c -r --opt:speed -d:debug --verbosity:0 --hints:off -d:chronicles_log_level=info ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"

  exec "nim -d:secure c -r --opt:speed -d:debug --verbosity:0 --hints:off -d:chronicles_log_level=info ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"
