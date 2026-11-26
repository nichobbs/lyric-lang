# D858: the native TIR lowering takes `UInt.toDouble` and `UInt.toFloat`

Status: accepted (docs/70 phase 4a, part 8; D520 slice 47).

## Decision

A `UInt` converts to `Double` or `Float` by zero-extending to 64 bits and converting as a signed value, which is exact for every `UInt` (`ULong` keeps its own pass, D508). `scripts/ci/native-via-tir/wrapping.l` pins a value above `Int.MaxValue`.
