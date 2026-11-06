# D384 - Mono no longer reports T0224; an unrecorded unpinned imported call is an internal M0002 (docs/70 phase 3a, #8760)

**Status:** shipped. Step two of the remaining #8760 plan; follows D383.

## Context

`Lyric.Mono` kept its own T0224 for a call to an imported generic whose type
argument nothing fixed, because the checker recorded only single-segment
callees (D339, D381, D382). D383 made the checker record package-qualified and
method calls, and the CI round of that change (the compiler, the stdlib, 81
library builds and the ecosystem tests) found no call the checker missed.

## Decision

Mono's T0224 and `noteUnpinnedTypeArgs` are deleted. The checker is the only
source of T0224. A call that still reaches the rewriter with a type argument
unresolved (and none of the three exemptions of `unpinnedCallKeepsErasedDefault`)
is a checker gap, not a user error: leaving it generic would make codegen drop
it silently (#5604), so Mono reports it as an internal M0002 that names the
call and asks for a bug report.

## Not in this change

The three exemptions (`@externTarget` host boundary, no source position, and
the unrecorded calls this change now makes loud) are the next steps of #8760.
A dot-named function called through its type name is still not recorded by the
checker (D383); it is not a shape this rewriter branch sees.

## Tests

`mono_self_test.l`: the four cases that pinned Mono's T0224 now pin the
internal M0002; the pinned and exempt cases are unchanged.
