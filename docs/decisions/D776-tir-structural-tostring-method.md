# `x.toString()` on a record, union, tuple or collection is the built-in toString (docs/70 phase 3a, #8613; extends D282)

**Status:** shipped; builder only.

## Context

D282 renders a record, a union, a tuple and a collection structurally, the same on every target, for `toString(x)`, `x.toString()`, interpolation and `+`. The checker types `x.toString()` `String` and records no callee, so the typed IR builder has to build the call. `buildToStringMethod` did so only for a range subtype or a distinct value; `structural_tostring_self_test.l` 77 (`p.toString()` on a record) and its native twin 81 were stopped by the gate (#9282): "the builder has no case for a call the checker did not resolve".

## Decision

`buildToStringMethod` builds the call as the built-in `toString` of the receiver for every receiver type D282 renders: a range subtype, a declared type that is not a host class (record, union, enum, distinct type, standard collection), a tuple, a slice and an array. A host class named by an `extern type` keeps the host's own `toString` and is not built here.

## Consequences

`structural_tostring_self_test` 77 and `structural_tostring_native_self_test` 81 build. Test: `tir_build_self_test.l`.
