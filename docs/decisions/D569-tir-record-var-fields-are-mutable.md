# D569 - A record's `var` fields are mutable in the package's symbol entries (docs/70 phase 3a, #8613)

**Status:** shipped; extends D338 and D360.

## Context

The builder wrote every record field of a `TSymEntry` with `mutable = false`, so the verifier's
`assign-mutable` rule (D323) rejected any assignment to a `var` field of a `ref record`. The standard
library's tests never assign one, so the existing census read zero; the wide census (`tir-census.sh --wide`, #8994) found 377 diagnostics outside them: 228 in the compiler's own sources, 149 in the ecosystem libraries
and the compiler's self-tests.

## Decision

`varFieldNames` reads the `var` fields of a record's declaration (`FieldDecl.isMutable`, language reference
§3.4) and both places that build a record's field list use it: the package's type entries and the entry noted for
a construction. A plain field stays immutable; a symbol that is no record has no `var` field.

## Measured

`tir_build_self_test.l` covers a `ref record` whose `var` field is assigned (it builds and verifies) and
checks both fields' mutability. The wide census over the compiler and the ecosystem libraries is in the
progress entry.
