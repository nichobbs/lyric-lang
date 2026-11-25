# D538: the native TIR lowering takes range-checked distinct types and the operators on distinct types

Status: accepted (docs/70 phase 4a, part 7; D520 slice 38).

## Decision

1. **Every distinct type is lowered**, with or without a range: it is its underlying type's representation (`TirLowerEnv.distincts`), and `TirLowerEnv.distinctInfos` carries what else the lowering reads of it (`TirDistinct`: signedness of the wrapped primitive, the range, the range message).
2. **Wrapping into a range-checked distinct type** (`CvWrapDistinct`, the `T.from(x)` call) compares the value with the bounds (unsigned for `Byte`/`UInt`/`ULong`, ordered floating-point compares for a `Double`/`Float` range, so a NaN is in no range) and panics with the AST path's text, `T.from: value out of range [lo, hi]`.
3. **Operators on a distinct type** (derived `+ - * /`, comparisons, unary `-`) follow the wrapped primitive (`opTy`): signedness, floating point and the overflow rule come from the `Byte`/`Int`/`UInt`/`Long`/`ULong`/`Float`/`Double` it wraps, not from the distinct type's own symbol. The result of an arithmetic operator or compound assignment whose type is a range-checked distinct type is range checked as `T.from` would (#7226), whether or not the builder wrapped it.

## Not done

`T.tryFrom` (`IoTryFrom`) still falls back: it builds a `Result[T, String]`, which the TIR lowering has no instance for yet.

## Verification

`scripts/ci/native-via-tir/ranged.l` (`Long`, `Byte` and `Double` ranges, `from`, derived `+`/`-`, a compound assignment on a record field, comparisons, an out-of-range panic) lowers 10 of 10 functions from TIR with the AST path's output and panic text, clean under AddressSanitizer.
