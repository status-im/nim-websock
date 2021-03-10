import bearssl

## Random helpers: similar as in stdlib, but with BrHmacDrbgContext rng
const randMax = 18_446_744_073_709_551_615'u64


proc rand*(rng: var BrHmacDrbgContext, max: Natural): int =
  if max == 0: return 0
  var x: uint64
  while true:
    brHmacDrbgGenerate(addr rng, addr x, csize_t(sizeof(x)))
    if x < randMax - (randMax mod (uint64(max) + 1'u64)): # against modulo bias
      return int(x mod (uint64(max) + 1'u64))

proc genMaskKey*(rng: ref BrHmacDrbgContext): array[4, char] =
  ## Generates a random key of 4 random chars.
  proc r(): char = char(rand(rng[], 255))
  return [r(), r(), r(), r()]

proc genWebSecKey*(rng: ref BrHmacDrbgContext): seq[byte] =
  var key = newSeq[byte](16)
  proc r(): byte = byte(rand(rng[], 255))
  ## Generates a random key of 16 random chars.
  for i in 0..15:
    key.add(r())
  return key
