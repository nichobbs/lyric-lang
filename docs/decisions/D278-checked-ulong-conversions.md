# D278 — Checked `ULong` conversions to `Long`, `Double` and `Float` (#8450, #7901)

**Status:** shipped

## Context

`UInt.toLong()`, `toDouble()` and `toFloat()` convert the unsigned value since #7901
(the checker zero-extends through `toULong()`). A `ULong` shares the 64-bit
representation of a `Long`, so a plain signed conversion reads the top bit as a
sign (`18446744073709551615u64.toLong()` was `-1`); until now the three methods on
a `ULong` were `T0103`, and `docs/01` §4.1 had no way to turn a `ULong` into a
signed or floating-point value.

## Decision

- `w.toLong()` on a `ULong` is **checked**: it panics with
  `ULong value is above Long.MaxValue and does not fit in a Long` when the value is
  above `9223372036854775807`. The check holds in every build profile and in the
  standard library (it is not an arithmetic overflow check, so the `release`
  profile and `wrapping*` do not turn it off). There is no `tryToLong` form: the
  explicit test is `w <= 9223372036854775807u64`.
- `w.toDouble()` and `w.toFloat()` convert the unsigned value, rounding to nearest
  even (`18446744073709551615u64.toDouble()` is `2^64`).
- The receiver's signedness is invisible to the backends (`ULong` and `Long` are
  both `MLong`), so the checker records the call as an overflow site
  (`ulong:<method>`) and `Lyric.ContractElaborator.lowerOverflowChecks` lowers it
  before any backend runs, to plain `Long` operations:
  - `toLong` binds the receiver once and panics if its `Long` reading is negative;
  - `toDouble` / `toFloat` convert directly when the `Long` reading is
    non-negative, and otherwise convert `((s shr 1) and Long.MaxValue) or (s and 1)`
    (the value halved with its low bit folded in, which keeps the single rounding
    exact) and double the result.
  The panic message and the results are therefore identical on MSIL and the JVM, with no backend change (`--target native` does not support the `ULong` type at all yet, so it has no surface for these conversions; the lowering is target-independent and applies when it does) and no dependency on `toNat` (which the JVM lacks
  on a `ULong` receiver).
- The conversions the lowering itself emits (zero-width spans) are plain `Long`
  conversions on a `ULong`-typed local; the checker neither records nor rejects them.
- T0147's hint (`-(x.toLong())`) is now valid for a `ULong`.

## Consequences

`docs/01` §4.1 and the book's quick reference describe the three conversions.
Tests: `lyric-compiler/lyric/conv_methods_self_test.l` (MSIL and JVM) and
`typechecker_self_test.l`.
