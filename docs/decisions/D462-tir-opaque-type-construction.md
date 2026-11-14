# D462 - An opaque type is constructed by its fields inside its own package (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

The ecosystem census counted 59 sites of "a method, constructor or member call". Sampling them (`SqlText(text = ..., placeholders = ...)`
in lyric-db, `StringBuilder(host = ...)` and `CompiledRegex(handle = ...)` in the standard library, `SubsegmentHandle()` in lyric-aws-xray)
showed one cause: the checker recorded the callee of the construction (`calleeByNode`) but not its fields (`ctorSigByNode`), because
`recordCtorSigNode` knew records, protected types and union cases but not an opaque type. The builder then had a callee with no signature
and fell through to the generic "member call" error.

## Decision

`recordCtorSigNode` records a non-generic opaque type's fields, read from its declaration with `ctorAllFields`, exactly as it does for a
protected type. An opaque type is constructible only in its own package, so the fields are always the declaration's. A generic opaque type
is not recorded yet and stays counted. The builder's `buildConstructCall` is unchanged: the type's own entry already carries the fields
(`opaqueEntry`, D592).
