## Nim-Libp2p
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

type
  WebSocketError* = object of CatchableError
  WSMalformedHeaderError* = object of WebSocketError
  WSFailedUpgradeError* = object of WebSocketError
  WSVersionError* = object of WebSocketError
  WSProtoMismatchError* = object of WebSocketError
  WSMaskMismatchError* = object of WebSocketError
  WSHandshakeError* = object of WebSocketError
  WSOpcodeMismatchError* = object of WebSocketError
  WSRsvMismatchError* = object of WebSocketError
  WSWrongUriSchemeError* = object of WebSocketError
  WSMaxMessageSizeError* = object of WebSocketError
  WSClosedError* = object of WebSocketError
  WSSendError* = object of WebSocketError
  WSPayloadTooLarge* = object of WebSocketError
  WSReserverdOpcodeError* = object of WebSocketError
  WSFragmentedControlFrameError* = object of WebSocketError
  WSInvalidCloseCodeError* = object of WebSocketError
  WSPayloadLengthError* = object of WebSocketError
  WSInvalidOpcodeError* = object of WebSocketError
