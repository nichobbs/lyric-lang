# D588 - Assigning to an `inout self` is an assignment to the receiver local (docs/70 phase 3a, #8613)

**Status:** shipped; extends the place builder of D358.

## Context

A method that takes `self: inout T` may replace its receiver: `self = Ctr(n = x)`. The place builder knew locals, fields and elements; `self` is the expression `ESelf`, not a path, so the assignment fell to `an assignment target that is not a local, field or element` (22 sites in the self-test area).

## Decision

- `self` as an assignment target is the local the body already declares for its receiver parameter: the place is `PlLocal` of that local, typed as the parameter. The assignment's mutability is the verifier's `assign-mutable` check on that local, which holds for an `inout` receiver.
- Outside a method (no local named `self`) the target is counted as `an assignment to self outside a method`, not guessed.

## Measured

`tir_build` 160 and `tir_verify` 27 pass; a new case builds and verifies `self = Ctr(n = 0)` in a method taking `self: inout Ctr`. The wide census was not re-measured for this change.
