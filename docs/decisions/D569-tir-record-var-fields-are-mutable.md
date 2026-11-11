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

`tir_build_self_test.l` covers a `ref record` whose `var` field is assigned: it builds, verifies, and the
`var` field is mutable while a plain field stays immutable. `tir-census.sh --wide` before and after (the
compiler's `Lyric.Cli` closure and the 38 ecosystem manifests): I0003 255 -> 27 in the compiler and
89 -> 0 in the ecosystem libraries; the 27 left are `call-result-type` (extern results) and
`pattern-arity`, not this rule. The ecosystem total of bodies differs between the two runs (3964 and 3337)
because two manifests that were unchecked before were judged and a dependent library is no longer
counted again; I0002 is unchanged by this decision. The standard-library gate is unchanged (1082 of 1165,
I0003 0).
