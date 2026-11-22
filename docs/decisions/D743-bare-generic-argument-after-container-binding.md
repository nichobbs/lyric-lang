# A bare `T` argument after a container fixed `T` does not unbind it (docs/70 phase 3a, #8613)

**Status:** shipped; checker.

## Context

`unwrapResultOr(r, Square(side = 0))` with `r: Result[Shape, String]` and `unwrapResultOr[T, E](r: in Result[T, E], d: in T): T`: the first argument fixes `T` to the interface `Shape`; the second, a `Square`, is a different type, so the inference returned the hole and the call had no type (`stdlib_generic_iface_self_test.l`).

## Decision

In `inferOneGenericArg`, an occurrence of `T` in a bare `T` parameter whose argument differs from a binding another, non-bare occurrence (inside `Result[T, E]`) fixed leaves the binding as it is. The argument must convert to the instantiated parameter, which the argument check against the signature still verifies (T0043 otherwise) and the typed IR records as a conversion.

## Results

`stdlib_generic_iface_self_test.l` 20 of 20.
