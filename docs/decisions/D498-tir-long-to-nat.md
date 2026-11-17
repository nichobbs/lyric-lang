# D498 - A Long passed to a Nat-backed factory is a checked conversion (docs/70 phase 3a, #8613)

**Status:** shipped; extends D319 (the typed IR).

## Context

`Score.from(n)` on a distinct or range type whose underlying type is `Nat` accepts a `Long` argument (a `Nat` is a non-negative `Long`, language reference 2.1). The builder converted the argument to the underlying type with `coerceArg`, which has no `Long` to `Nat` conversion (the language has no implicit one), so the call was counted as "an argument conversion" (I0002).

## Decision

`ConvKind` gains `CvLongToNat`: the operand is a `Long`, the node a `Nat`, and the value must be non-negative (a panic otherwise, as `.toNat()`). `buildDistinctFactory` wraps a `Long` argument in it when the underlying type is `Nat`. The verifier checks the operand and node types (`convert-type`); the interface format writes tag 15 (append-only).

## Results

`tir_build_self_test.l` builds `Score.from(n)` with `n: Long` and `Score = Nat range 0 ..= 1000` with 0 I0002 and 0 I0003; `tir_verify_self_test.l` rejects the conversion on other types.
