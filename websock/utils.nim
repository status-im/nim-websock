## nim-websock
## Copyright (c) 2021-2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import bearssl/rand

type SecureRngContext* = HmacDrbgContext

export rand.generate

## Random helpers: similar as in stdlib, but with SecureRngContext rng
# TODO: Move these somewhere else?
const randMax = 18_446_744_073_709_551_615'u64

proc rand*(rng: var SecureRngContext, max: Natural): int =
  if max == 0: return 0

  var x: uint64
  while true:
    rng.generate(x)
    if x < randMax - (randMax mod (uint64(max) + 1'u64)): # against modulo bias
      return int(x mod (uint64(max) + 1'u64))

proc genMaskKey*(rng: ref SecureRngContext): array[4, char] =
  ## Generates a random key of 4 random chars.
  proc r(): char = char(rand(rng[], 255))
  return [r(), r(), r(), r()]

proc genWebSecKey*(rng: ref SecureRngContext): seq[byte] =
  var key = newSeq[byte](16)
  proc r(): byte = byte(rand(rng[], 255))
  ## Generates a random key of 16 random chars.
  for i in 0..15:
    key[i] = r()
  return key
