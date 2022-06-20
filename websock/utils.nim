## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import bearssl/[rand]
export rand

## Random helpers: similar as in stdlib, but with HmacDrbgContext rng
const randMax = 18_446_744_073_709_551_615'u64

type
  Rng* = ref HmacDrbgContext

proc newRng*(): Rng =
  # You should only create one instance of the RNG per application / library
  # Ref is used so that it can be shared between components
  HmacDrbgContext.new()

proc rand*(rng: Rng, max: Natural): int =
  if max == 0: return 0
  var x: uint64
  while true:
    let x = rng[].generate(uint64)
    if x < randMax - (randMax mod (uint64(max) + 1'u64)): # against modulo bias
      return int(x mod (uint64(max) + 1'u64))

proc genMaskKey*(rng: Rng): array[4, char] =
  ## Generates a random key of 4 random chars.
  proc r(): char = char(rand(rng, 255))
  return [r(), r(), r(), r()]

proc genWebSecKey*(rng: Rng): seq[byte] =
  var key = newSeq[byte](16)
  proc r(): byte = byte(rand(rng, 255))
  ## Generates a random key of 16 random chars.
  for i in 0..15:
    key[i] = r()
  return key
