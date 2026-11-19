# D348 - A `match` whose arms all diverge has type `Never` (docs/70 phase 3a, #8613)

**Status:** shipped; internal to the checker, no change to what programs are accepted.

## Context

The checker joined a `match`'s arm types starting from a silent `TyError`, which absorbs a `Never` arm (`unifyBranchTypes` returns the other type when one is `Never`, and the accumulator was an error, not a type), so a `match` whose arms all `panic` or `return` was typed `TyError` with no diagnostic. An `if` with two diverging branches was typed `Never`. A function whose tail is such a `match` and whose return type is `Unit` (a diagnostic helper, `Msil.Codegen::panicExternSetterUnresolved`) has nothing to settle the tail against, so the builder counted the body (I0002, "the checker gave no usable type").

## Decision

The fold starts at `Never`: a `match` with at least one arm that yields a type has that type as before; a `match` whose arms all diverge is `Never`; an arm that is a reported error still makes the join the error. Arms are never zero in a parsed `match`.

## Results

`panicExternSetterUnresolved` builds; the new `tir_build_self_test.l` case builds a `Unit` function ending in an all-`panic` `match`; `typechecker_self_test.l` passes unchanged.
