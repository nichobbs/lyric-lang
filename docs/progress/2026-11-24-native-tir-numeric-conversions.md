# 2026-11-24: native TIR lowers the numeric conversion and bitwise builtins (D532)

`Int/Long/Byte/UInt/ULong/Double/Float/Char` conversions (`toFloat`, `toDouble`, `toInt`, `toLong`, `toByte`, `toUInt`, `toULong`, the checked `toNat` and `toChar`) and `.and/.or/.xor/.shl/.shr` now lower from TIR on `--target native`, with the AST path's semantics and panic messages. Unsigned to floating point stays on the AST path (see D532). Covered by `scripts/ci/native-via-tir/numeric.l` under AddressSanitizer.
