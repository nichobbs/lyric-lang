# `toInt` and `toLong` of a `Nat` are built-in conversions (docs/70 phase 3a, #8613)

**Status:** shipped; checker.

## Context

`n.toNat().toInt()` left the second call unresolved: a `Nat` was not a receiver the conversion methods accepted (`isNumericOrCharType`), so the call fell through to untyped dispatch that only worked because `Nat` and `Long` share their backend representation (`int_to_nat_self_test.l`).

## Decision

`toInt` and `toLong` on a `Nat` are recorded as the built-ins `Nat.toInt` and `Nat.toLong`, typed `Int` and `Long`, exactly as `Long.toInt()` is. A `Nat` is a non-negative `Long` (docs/01 section 2.1), so the conversions are the `Long` ones on every backend. The other conversions from a `Nat` stay unsupported, as the checker's comment on the receiver whitelist says.

## Results

`tir-builder-shapes-e2e.sh` (`nat_conversions`); `int_to_nat_self_test.l` builds under the gate.
