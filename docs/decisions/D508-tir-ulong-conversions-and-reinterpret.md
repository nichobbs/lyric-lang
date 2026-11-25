# D508 - `ULong` conversions on TIR over a same-width `CvReinterpret`

**Status:** accepted, implemented as `Lyric.Tir.Unsigned` (docs/70 phase 3c, §7.2; the TIR counterpart of D278's `ulongConversion`)

## Decision

1. **`CvReinterpret`, one general `ConvKind`**: `XConvert(CvReinterpret, e)` reads the bits of `e` at the other signedness of the same width. The operand and the node are `Int` and `UInt`, or `Long` and `ULong`, one each, in either order; there is no range check and no rounding, so a backend lowers it as the identity on the value's representation. `Lyric.Tir.Verify` reports a `convert-type` diagnostic for any other pair; the interface writer gives it tag 18; native lowers it as `lowerExpr(inner)`. It is not `ULong`-specific, and no builder rule emits it: only passes do.
2. **`Lyric.Tir.Unsigned.lowerUnsignedBundle`** (`Pipeline.pipeUnsignedTir`) rewrites the built-ins `ULong.toLong`, `ULong.toDouble` and `ULong.toFloat`, which a backend cannot tell from the plain 64-bit conversion, into the block the AST pass builds: `toLong` binds the receiver, reads it with `CvReinterpret` and panics with `ULong value is above Long.MaxValue and does not fit in a Long` when that reading is negative; `toDouble` and `toFloat` convert directly when it is not, and otherwise convert `((s shr 1) and Long.MaxValue) or (s and 1)` and double the result (the halved value with its low bit folded in keeps the single rounding exact). The conversions inside are `Long` built-ins every backend already lowers, so no `uitofp` node exists.
3. **Order**: after `?` lowering, before contract elaboration and monomorphisation; the native bridge runs it right after `pipePropagateTir`. Node ids from 750,000,000, locals from 1,550,000,000 per function.

## Not done

The MSIL and JVM TIR backends (phase 4) will lower `CvReinterpret` as a no-op on the same stack type when they consume TIR.
