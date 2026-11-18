# D454 - A generic opaque or protected type's construction has a recorded signature (docs/70 phase 3a, #8613)

**Status:** shipped; extends D388 and D452.

## Context

`recordCtorSigNode` returned early for a generic opaque or protected type, so every construction of one (`Opq(v = x)`, `Cell(value = v)`) was counted as "a method, constructor or member call" (I0002): the generic opaque, generic protected and value-generic protected self-tests.

## Decision

The type's own parameters are pushed into a generic context owned by the declaration, each field type is resolved there and substituted at the result type's arguments, as a generic record's fields are (`fieldsOfRecordSubstituted`). A result type whose argument count differs from the declaration's records nothing. The builder needed no change.

## Results

`tir_build_self_test.l` builds a generic opaque construction, a generic protected construction at a closed type and one at a function's own parameter, each with every body built (`built == total`) and 0 I0003.
