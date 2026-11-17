# D496 - An index of any integer type keeps its own type (docs/70 phase 3a, #8613)

**Status:** shipped; extends D319 (the typed IR).

## Context

The language reference allows an array index of `Int`, `Long`, `Byte`, `UInt` or `ULong` (a non-`Int` index is range checked as a `Long` before it is narrowed). The builder converted every index to `Int` and had no such conversion for a `Long`, so `a[i]` with `i: Long` was counted as "an argument conversion" (I0002).

## Decision

`buildIndexParts` leaves an integer primitive index as it is when the key type is `Int`; the node carries the index's own type and a backend does the range check and the narrowing. Other index types still go through `coerceArg` (range subtypes, distinct types).

## Results

`tir_build_self_test.l` builds an array read indexed by a `Long` with 0 I0002 and 0 I0003.
