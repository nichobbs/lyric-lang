# ULong conversions on TIR over `CvReinterpret` (docs/70 phase 3c)

Decision: D508.

## What shipped

- `ConvKind.CvReinterpret` (Verify rule, interface codec tag 18, native lowering) and `Lyric.Tir.Unsigned` / `Pipeline.pipeUnsignedTir`: D278's checked `toLong` and corrected `toDouble`/`toFloat` as blocks over the reinterpret.
- The native bridge runs the pass after `?` lowering; `lowerNumericConversion`'s `ULong` early return no longer fires for bundles that went through it.
- `lyric-compiler/lyric/tir_unsigned_self_test.l`: the three conversions, a nested one, an unchanged function, and a Verify rejection of a bad reinterpret.
