## Nim-Libp2p
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/[chronos, chronicles]
import ./frame

type
  Extension* = ref object of RootObj
    name*: string

proc `name=`*(self: Extension, name: string) =
  raiseAssert "Can't change extensions name!"

method decode*(self: Extension, frame: Frame): Future[Frame] {.base, async.} =
  raiseAssert "Not implemented!"

method encode*(self: Extension, frame: Frame): Future[Frame] {.base, async.} =
  raiseAssert "Not implemented!"
