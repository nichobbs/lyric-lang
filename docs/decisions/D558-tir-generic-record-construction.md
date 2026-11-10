# D558 - A generic record's construction is recorded at its result type (docs/70 phase 3a, #8613)

**Status:** shipped; extends D388.

## Context

D388 records a construction's signature (`ctorSigByNode`) so the builder can place and convert its
arguments as a call's. A record's fields were read from its declaration, so only a non-generic record
had one, and a construction that met an expected type (`val q: Pair[Int, String] = Pair(...)`) went
through a checker path that recorded neither the callee nor the signature. Both showed up in the TIR
census as `a method, constructor or member call` (a `MapEntry(key = 1, value = "one")` argument of
`List.add`).

## Decision

`recordCtorSigNode` instantiates a generic record's fields at the closed result type's arguments
(`fieldsOfRecordInstantiated`), as it does for a union case, and the expected-type construction path
records its callee and signature as the other path does. The builder leaves a generic record's symbol
entry to `typeEntries` (the declaration's own, under its parameters), since the instantiated field
types a construction's signature carries are not the record's fields. A construction whose result type
still has an unsolved hole has no signature and stays counted (the larger case of union-case
constructions passed as arguments of generic calls, left for its own slice).

## Measured

`scripts/ci/tir-census.sh` over the 98 programs, on top of D556: bodies built 1006 -> 1007 of 1165,
`a method, constructor or member call` 56 -> 54, I0003 0; `collections_persistent_map_tests.l` builds all 10 bodies.
