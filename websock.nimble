## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

packageName = "websock"
version     = "0.1.0"
author      = "Status Research & Development GmbH"
description = "WS protocol implementation"
license     = "MIT"
skipDirs    = @["examples", "tests"]

requires "nim >= 1.2.0" # nimble will fail to install nim-websock if we are using 1.2.6 here
requires "chronos >= 3.0.0"
requires "httputils >= 0.2.0"
requires "chronicles >= 0.10.2"
requires "stew >= 0.1.0"
requires "nimcrypto"
requires "bearssl"
requires "zlib"

task test, "run tests":
  let
    envNimflags = getEnv("NIMFLAGS")
    styleCheckStyle =
      if (NimMajor, NimMinor) < (1, 6):
        "hint"
      else:
        "error"
    nimFlags = envNimFlags &
      " --verbosity:0 --hints:off --hint:Name:on " &
      "--styleCheck:usages --styleCheck:" & styleCheckStyle &
      " -d:chronosStrictException"

  # dont't need to run it, only want to test if it is compileable
  exec "nim c -c " & nimFlags & " -d:chronicles_log_level=TRACE -d:chronicles_sinks:json --styleCheck:usages --styleCheck:hint ./tests/all_tests"

  exec "nim c -r " & nimFlags & " --opt:speed -d:debug -d:chronicles_log_level=INFO ./tests/all_tests.nim"
  rmFile "./tests/all_tests"

  exec "nim c -r " & nimFlags & " --opt:speed -d:debug -d:chronicles_log_level=INFO ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"

  exec "nim -d:secure c -r " & nimFlags & " --opt:speed -d:debug -d:chronicles_log_level=INFO ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"

  exec "nim -d:accepts c -r " & nimFlags & " --opt:speed -d:debug -d:chronicles_log_level=INFO ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"

  exec "nim -d:secure -d:accepts c -r " & nimFlags & " --opt:speed -d:debug -d:chronicles_log_level=INFO ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"
