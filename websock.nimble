## nim-websock
## Copyright (c) 2023-2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

packageName = "websock"
version     = "0.3.0"
author      = "Status Research & Development GmbH"
description = "WS protocol implementation"
license     = "MIT"
skipDirs    = @["examples", "tests"]

requires "nim >= 2.0.16"
requires "chronos >= 4.2.0 & < 4.4.0"
requires "httputils >= 0.2.0"
requires "chronicles >= 0.10.2"
requires "stew >= 0.4.2"
requires "nimcrypto"
requires "bearssl"
requires "results"
requires "zlib"

proc build(params: string) =
  let cmdPrefix = "nim c " & getEnv("NIMFLAGS") &
    " --verbosity:0 --styleCheck:usages --styleCheck:error --mm:"
  exec cmdPrefix & "orc " & params
  exec cmdPrefix & "refc " & params

task test, "run tests":
  # dont't need to run it, only want to test if it is compileable
  build "-c -d:chronicles_log_level=TRACE -d:chronicles_sinks:json ./tests/all_tests"

  build "-r --opt:speed -d:chronicles_log_level=INFO ./tests/all_tests.nim"
  rmFile "./tests/all_tests"

  build "-r --opt:speed -d:chronicles_log_level=INFO ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"

  build "-d:secure -r --opt:speed -d:chronicles_log_level=INFO ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"

  build "-d:accepts -r --opt:speed -d:chronicles_log_level=INFO ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"

  build "-d:secure -d:accepts -r --opt:speed -d:chronicles_log_level=INFO ./tests/testwebsockets.nim"
  rmFile "./tests/testwebsockets"
