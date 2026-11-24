# D532: numeric conversions and bitwise methods lower from TIR on native

Status: accepted (docs/70 phase 4a, part 5; D520 slice 33).

## Decision

The TIR lowering of the compiler's numeric builtins (`<Type>.toX`, `<Type>.and/or/xor/shl/shr`) covers the family the AST path lowers:

- `toFloat`/`toDouble` from every signed width and `Byte` (a `Byte` zero-extends first), `Double` to `Float` by truncation, and a `Float` receiver converted as the `Double` it widens to exactly.
- `toInt`/`toLong`/`toByte`/`toUInt`/`toULong` between every width: a widening from an unsigned source (or to `UInt`/`ULong`) zero-extends, a signed one sign-extends, a narrowing truncates, and a `Double` source truncates toward zero (a `Byte` keeps the low 8 bits of the `Long`).
- The checked `toNat` (a negative value or NaN panics with `toNat: value must be non-negative`) and `toChar` (a value above U+FFFF or a surrogate panics with the shared message), with the same panic text as the AST path.
- `.and/.or/.xor/.shl/.shr` on any integer width; the shift amount is converted to the operand's width, and `.shr` is logical for `Byte`, `UInt` and `ULong`, arithmetic otherwise.

`ULong.toLong`, `ULong.toDouble` and `ULong.toFloat` stay on the AST path: the contract elaborator rewrites them into a checked or corrected block (D278, always on), and TIR does not carry that rewrite until phase 3c, so lowering them here would convert unchecked. Unsigned `UInt` to floating point and `Double` to `UInt`/`ULong` also stay on the AST path.

## Verification

`scripts/ci/native-via-tir/numeric.l` runs both ways and under AddressSanitizer with no TIR fallback; the e2e also compiles a negative `toNat` and a surrogate `toChar` through both paths and compares the panic message.
