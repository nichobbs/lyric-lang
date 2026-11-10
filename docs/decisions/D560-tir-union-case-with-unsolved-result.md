# D560 - A union case's construction is recorded from its closed field types (docs/70 phase 3a, #8613)

**Status:** shipped; extends D388 and D557-era notes in D558.

## Context

`recordCtorSigNode` recorded a union case's construction only when its whole result type was closed.
`Err(error = 1)` as an argument of a generic call is a `Result[?, Int]`: the type argument no
argument fixes stays a hole until the enclosing call's parameter settles it, so the construction
had no signature and counted as `a method, constructor or member call` (the largest census kind
after the cascade). The case's own fields, though, are closed (`error: Int`), and the builder
already takes the node's type from the settled parameter type.

## Decision

For a union case, the checker records the construction signature when every instantiated field type
is closed, whatever the result type's remaining arguments are. A case whose field types still hold
a hole (a payload that itself depends on the unsolved argument) has no signature and stays counted.
Records and protected types are unchanged (they still need a closed result type when generic).

## Measured

`scripts/ci/tir-census.sh` over the 98 programs, on top of D559: bodies built 1016 -> 1028 of 1165,
I0003 0; `a name that is not a local` (the cascade) 64 -> 38.
