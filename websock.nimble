## nim-websock
## Copyright (c) 2023-2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

mode = ScriptMode.Verbose

packageName   = "websock"
version       = "0.5.0"
author        = "Status Research & Development GmbH"
description   = "WS protocol implementation"
license       = "MIT"
skipDirs      = @["examples", "tests"]

requires "nim >= 2.2.14",
         "bearssl >= 0.2.13",
         "chronicles >= 0.12.4",
         "chronos >= 4.4.0 & < 4.6.0",
         "httputils >= 0.5.1",
         "nimcrypto >= 0.7.0",
         "results >= 0.5.0",
         "stew >= 0.5.2",
         "zlib >= 0.2.0"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]
let platform = getEnv("PLATFORM", "")
let testArguments = [
  "",
  "-d:secure",
  "-d:accepts",
  "-d:secure -d:accepts",
]

from std/os import quoteShell

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0") &
  " --skipParentCfg --skipUserCfg --outdir:build -f " &
  quoteShell("--nimcache:build/nimcache/$projectName")

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path

proc runTests(args: string) =
  # dont't need to run it, only want to test if it is compileable
  build args & " -c -d:chronicles_log_level=TRACE -d:chronicles_sinks:json", "tests/all_tests"

  run args, "tests/all_tests"
  for testArgs in testArguments:
    run args & " " & testArgs, "tests/testwebsockets"

task test, "Run all tests":
  runTests "--mm:orc"
  runTests "--mm:refc"

task test_asan, "Run all tests with ASAN":
  if platform != "x86":
    # https://clang.llvm.org/docs/AddressSanitizer.html
    putEnv("ASAN_OPTIONS", "detect_leaks=0:detect_stack_use_after_return=1")
    # https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
    putEnv("UBSAN_OPTIONS", "print_stacktrace=1")
    let asanArgs =
      " --mm:orc -d:useMalloc --cc:clang --debugger:native" &
      " --passC:-fsanitize=address,undefined" &
      " --passL:-fsanitize=address,undefined" &
      " --passC:-fno-sanitize-recover=undefined" &
      " --passC:-fno-sanitize-merge" &
      " --passC:-fno-omit-frame-pointer"
    runTests asanArgs
