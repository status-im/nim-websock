## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# DFA based UTF8 decoder/validator
# See https://bjoern.hoehrmann.de/utf-8/decoder/dfa/ for details.

const
  UTF8_ACCEPT = 0
  UTF8_REJECT = 1

const utf8Table = [
  0'u8,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, # 00..1f
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, # 20..3f
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, # 40..5f
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, # 60..7f
  1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, # 80..9f
  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7, # a0..bf
  8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, # c0..df
  0xa,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x4,0x3,0x3, # e0..ef
  0xb,0x6,0x6,0x6,0x5,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8, # f0..ff
  0x0,0x1,0x2,0x3,0x5,0x8,0x7,0x1,0x1,0x1,0x4,0x6,0x1,0x1,0x1,0x1, # s0..s0
  1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,0,1,0,1,1,1,1,1,1, # s1..s2
  1,2,1,1,1,1,1,2,1,2,1,1,1,1,1,1,1,1,1,1,1,1,1,2,1,1,1,1,1,1,1,1, # s3..s4
  1,2,1,1,1,1,1,1,1,2,1,1,1,1,1,1,1,1,1,1,1,1,1,3,1,3,1,1,1,1,1,1, # s5..s6
  1,3,1,1,1,1,1,3,1,3,1,1,1,1,1,1,1,3,1,1,1,1,1,1,1,1,1,1,1,1,1,1, # s7..s8
]


proc utf8Count*[T: byte|char](s: openArray[T]): (int,int) {.inline.} =
  ## Count utf8 related entities of argument string `s`. The function returns
  ## the integer pair
  ## ::
  ##   (<#code-points>,<#bytes-parsed>)
  ##
  ## where the first integer `<#code-points>` is the number of correctly parsed
  ## leading code points. The second integer `<#bytes-parsed>` is the number of
  ## bytes these code points have when `utf8` encoded.
  ##
  ## As a consequence, checking whether a given utf8 encoded `text` is correct
  ## using this function would read
  ## ::
  ##   text.utf8Count[1] == text.len
  ##
  ## i.e. the size of leading code points is all of the `text`.
  var
    state = UTF8_ACCEPT
    rdPos = 0

  while rdPos < s.len:
    let
      charClass = utf8Table[s[rdPos].int].int
      newState = utf8Table[256 + state*16 + charClass].int

    # Character was processed
    rdPos.inc

    # Update result state not until the code point is complete
    if newState == UTF8_ACCEPT:
      result[0].inc
      result[1] = rdPos
    elif newState == UTF8_REJECT:
      return

    # Ready for next character
    state = newState

proc utf8Prequel*[T: byte|char](s: openArray[T]): int {.inline.} =
  ## Shortcut for `s.utf8Count[1]` which is the maximum length of
  ## leading utf8 characters as byte sequence.
  s.utf8Count[1]

proc validateUTF8*[T: byte | char](text: openArray[T]): bool =
  ## Return `true` if the argument `text` is a valid utf8 encoded text.
  text.utf8Count[1] == text.len

# End
