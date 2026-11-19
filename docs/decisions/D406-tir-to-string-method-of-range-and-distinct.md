# D406 - `x.toString()` on a range-subtype or distinct value builds as the built-in `toString` (docs/70 phase 3a, #8613)

**Status:** shipped; extends the conversion methods of range and distinct types (D453, D428).

## Context

`c.toString()` on a value of a range subtype (`type Cents = Long range 0 ..= 1000000`) or a distinct type is typed `String` and the checker records no callee for it, in the package that declares the type and in one that restores it alike. The builder had no case for it and counted the body ("a call the checker did not resolve", I0002): `CpRange.App::show` and `CpRangeJvm.App::show`.

## Decision

A call `x.toString()` with no arguments, typed `String`, on a receiver whose type is a range subtype or a distinct type builds as the built-in `toString` of the receiver, the call `toString(x)` already builds (the same node an interpolated part of that type becomes). A receiver of any other type keeps the callee the checker records for it.

## Results

`range_to_string_method` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` (every body built, verifier clean) and runs (exit 3); a restored range subtype's `c.toString()` builds in a consumer package (2 of 2 bodies).
