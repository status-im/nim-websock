packageName = "ws"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "WS protocol implementation"
license = "MIT"

requires "nim >= 1.2.6"
requires "chronos >= 2.5.2 & < 3.0.0"

task lint, "format source files according to the official style guide":
  exec "./lint.nims"
