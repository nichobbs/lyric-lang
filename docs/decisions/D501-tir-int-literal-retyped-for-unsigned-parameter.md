# D501 - An unsuffixed literal too large for Int is retyped for a UInt or ULong argument

**Status:** accepted, implemented in `Lyric.Tir.Build` `convertValue` (docs/70 phase 3c follow-up to D396)

## Decision

docs/01 §1 lets an unsuffixed integer literal adopt the integer type its context expects when the value fits. The builder retyped such a literal only when the checker had typed it `Int`, so `f(200u8, 3000000000)` for a `UInt` parameter (the literal is a `Long`, being above `Int`'s range) failed with I0002 "no case for an argument conversion from Long to UInt" on `--target native`. `convertValue` now retypes a `Long` literal to `Byte`, `UInt` or `ULong` when its value is in that type's range, the same node with the expected type, not a conversion. A value outside the range still has no conversion.
