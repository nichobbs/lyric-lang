# D401 - A function body the checker left open takes the declared return type (docs/70 phase 3a, #8613)

**Status:** shipped; extends the settled types of D366 (`env.settled`).

## Context

A body whose value is a nullary case of a union over a value parameter (`func empty[N: Nat](): Shape[N] = Shape.Empty`) has no closed type when the checker types it: `Shape[N]` is not closed over the function's own parameters, so the expected type does not settle the node and the checker records `<error>`. The builder settled an expression from the expected type of a binding, an argument, a branch and the like, but not from the function's own return type, so the body was counted ("the checker gave no usable type for an expression the checker could not type", I0002): `ValueGenericRecordSelfTest::emptyShape`. The same function with the value bound to an annotated local, or at a concrete length, built.

## Decision

The builder settles the function body's tail expression (the expression body, or the last expression of a block) at the declared return type before building it, as it does a branch's value. `settle` is a fallback: it applies only to a node the checker typed with an error, so a node the checker typed keeps its own type.

## Results

`value_generic_record_self_test.l` builds every body (20 of 20; 19 before) with the verifier clean; a new `tir_build_self_test.l` case covers the expression and block forms.
