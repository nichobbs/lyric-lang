# `Pkg.Type.from(x)` builds as the distinct factory (docs/70 phase 3a, #8613)

**Status:** shipped; typed IR builder (the checker half is D745).

## Decision

`buildDistinctFactory` accepts a receiver that is a dotted name (`isNameChain`), as well as a single path, so a type named through its package builds as `T.from(x)` / `T.tryFrom(x)`.

## Results

`distinct_ops_self_test.l` 9 of 9 with D745.
