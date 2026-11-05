# D382 - Mono's result-type inference no longer fills an unpinned type argument with Object (docs/70 phase 3a, #8760)

**Status:** shipped. Step three of D353; follows D381.

## Context

`Lyric.Mono`'s result-type inference (`inferReturnFromName`) typed a call whose
type parameters nothing pinned by filling them with `Object` in two cases:
`ctorFill` for an inference-only union-case synth (`Ok(value = 7)` was
`Result[Int, Object]`) and `importedFill` for an imported, non-axiom generic.
docs/70 section 5.2 removes the erased default. Since D335/D339 an unpinned
type argument of a call is T0224, and since D381 an unsolved construction is
too, so the fills could only type a value the checker had already rejected.

## Decision

Both fills, the opacity tracking that fed `importedFill`, and the comments that
described them are deleted. A call whose type parameters stay open after the
arguments, the expected type and the checker's resolved type arguments
(`fillCheckedTypeArgsMono`) is not typed, so a binding of it is untyped rather
than typed at an instantiation the value never had.

## Not in this change

The call rewriter keeps `unpinnedCallKeepsErasedDefault` (the three named
exemptions: an `@externTarget` host boundary, a call without a source
position, a call the checker did not record) and its own T0224, since the
checker records only single-segment callees. They go when the checker records
qualified and member callees and the expansions carry type arguments (docs/70
phase 3a, #8760).

## Tests

No Mono test pinned the deleted code: the "partially-pinned union-ctor argument
mixes concrete and Object slots" test was removed with D335, and the remaining
`__Object` specialisations asserted in `mono_self_test.l` come from the
rewriter's ambiguous-overload fallback, which this change does not touch. The
T0224 cases of D335/D339 cover the new behaviour.
