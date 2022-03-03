## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/[chronos,
            chronos/streams/tlsstream,
            chronos/apps/http/httptable,
            httputils,
            stew/results]
import ./utils

const
  SHA1DigestSize* = 20
  WSHeaderSize* = 12
  WSDefaultVersion* = 13
  WSDefaultFrameSize* = 1 shl 20 # 1mb
  WSMaxMessageSize* = 20 shl 20  # 20mb
  WSGuid* = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type
  ReadyState* {.pure.} = enum
    Connecting = 0 # The connection is not yet open.
    Open = 1       # The connection is open and ready to communicate.
    Closing = 2    # The connection is in the process of closing.
    Closed = 3     # The connection is closed or couldn't be opened.

  Opcode* {.pure.} = enum
    ## 4 bits. Defines the interpretation of the "Payload data".
    Cont = 0x0   ## Denotes a continuation frame.
    Text = 0x1   ## Denotes a text frame.
    Binary = 0x2 ## Denotes a binary frame.
    # 3-7 are reserved for further non-control frames.
    Close = 0x8  ## Denotes a connection close.
    Ping = 0x9   ## Denotes a ping.
    Pong = 0xa   ## Denotes a pong.
    # B-F are reserved for further control frames.
    Reserved = 0xf

  HeaderFlag* {.pure, size: sizeof(uint8).} = enum
    rsv3
    rsv2
    rsv1
    fin

  HeaderFlags* = set[HeaderFlag]

  MaskKey* = array[4, char]

  Frame* = ref object
    fin*: bool                 ## Indicates that this is the final fragment in a message.
    rsv1*: bool                ## MUST be 0 unless negotiated that defines meanings
    rsv2*: bool                ## MUST be 0
    rsv3*: bool                ## MUST be 0
    opcode*: Opcode            ## Defines the interpretation of the "Payload data".
    mask*: bool                ## Defines whether the "Payload data" is masked.
    data*: seq[byte]           ## Payload data
    maskKey*: MaskKey          ## Masking key
    length*: uint64            ## Message size.
    consumed*: uint64          ## how much has been consumed from the frame
    offset*: int               ## offset of buffered payload data

  StatusCodes* = distinct range[0..4999]

  ControlCb* = proc(data: openArray[byte] = [])
    {.gcsafe, raises: [Defect].}

  CloseResult* = tuple
    code: StatusCodes
    reason: string

  CloseCb* = proc(code: StatusCodes, reason: string):
    CloseResult {.gcsafe, raises: [Defect].}

  WebSocket* = ref object of RootObj
    extensions*: seq[Ext]
    version*: uint
    key*: string
    readyState*: ReadyState
    masked*: bool             # send masked packets
    binary*: bool             # is payload binary?
    flags*: set[TLSFlags]
    rng*: Rng
    frameSize*: int           # max frame buffer size
    onPing*: ControlCb
    onPong*: ControlCb
    onClose*: CloseCb

  WSSession* = ref object of WebSocket
    stream*: AsyncStream
    frame*: Frame
    first*: bool
    proto*: string

  Ext* = ref object of RootObj
    name*: string
    session*: WSSession

  ExtParam* = object
    name* : string
    value*: string

  ExtFactoryProc* = proc(
    isServer: bool,
    args: seq[ExtParam]): Result[Ext, string]
    {.gcsafe, raises: [Defect].}

  ExtFactory* = object
    name*: string
    factory*: ExtFactoryProc
    clientOffer*: string

  # client exec order:
  #   1. append to request header
  #   2. verify response header
  # server exec order:
  #   1. verify request header
  #   2. append to response header
  # ------------------------------
  # Handshake exec order:
  # 1. client append to request header
  # 2. server verify request header
  # 3. server reply with response header
  # 4. client verify response header from server
  Hook* = ref object of RootObj
    append*: proc(ctx: Hook,
                  headers: var HttpTable): Result[void, string]
                  {.gcsafe, raises: [Defect].}
    verify*: proc(ctx: Hook,
                  headers: HttpTable): Future[Result[void, string]]
                  {.closure, gcsafe, raises: [Defect].}

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
  WSReservedOpcodeError* = object of WebSocketError
  WSFragmentedControlFrameError* = object of WebSocketError
  WSInvalidCloseCodeError* = object of WebSocketError
  WSPayloadLengthError* = object of WebSocketError
  WSInvalidOpcodeError* = object of WebSocketError
  WSInvalidUTF8* = object of WebSocketError
  WSExtError* = object of WebSocketError
  WSHookError* = object of WebSocketError

const
  StatusNotUsed* = (StatusCodes(0)..StatusCodes(999))
  StatusFulfilled* = StatusCodes(1000)
  StatusGoingAway* = StatusCodes(1001)
  StatusProtocolError* = StatusCodes(1002)
  StatusCannotAccept* = StatusCodes(1003)
  StatusReserved* = StatusCodes(1004)                      # 1004 reserved
  StatusNoStatus* = StatusCodes(1005)                      # use by clients
  StatusClosedAbnormally* = StatusCodes(1006)              # use by clients
  StatusInconsistent* = StatusCodes(1007)
  StatusPolicyError* = StatusCodes(1008)
  StatusTooLarge* = StatusCodes(1009)
  StatusNoExtensions* = StatusCodes(1010)
  StatusUnexpectedError* = StatusCodes(1011)
  StatusFailedTls* = StatusCodes(1015)                            # passed to applications to indicate TLS errors
  StatusReservedProtocol* = StatusCodes(1016)..StatusCodes(2999)  # reserved for this protocol
  StatusLibsCodes* = (StatusCodes(3000)..StatusCodes(3999))       # 3000-3999 reserved for libs
  StatusAppsCodes* = (StatusCodes(4000)..StatusCodes(4999))       # 4000-4999 reserved for apps

proc `<=`*(a, b: StatusCodes): bool = a.uint16 <= b.uint16
proc `>=`*(a, b: StatusCodes): bool = a.uint16 >= b.uint16
proc `<`*(a, b: StatusCodes): bool = a.uint16 < b.uint16
proc `>`*(a, b: StatusCodes): bool = a.uint16 > b.uint16
proc `==`*(a, b: StatusCodes): bool = a.uint16 == b.uint16

proc high*(a: HSlice[StatusCodes, StatusCodes]): uint16 = a.b.uint16
proc low*(a: HSlice[StatusCodes, StatusCodes]): uint16 = a.a.uint16

proc `$`*(a: StatusCodes): string = $(a.int)

proc `name=`*(self: Ext, name: string) =
  raiseAssert "Can't change extensions name!"

method decode*(self: Ext, frame: Frame): Future[Frame] {.base, async.} =
  raiseAssert "Not implemented!"

method encode*(self: Ext, frame: Frame): Future[Frame] {.base, async.} =
  raiseAssert "Not implemented!"

method toHttpOptions*(self: Ext): string {.base.} =
  raiseAssert "Not implemented!"
