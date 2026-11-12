# D571 - A failed binding's names are poisoned (docs/70 phase 3a, #8613)

**Status:** shipped; extends D366.

## Context

When a `val`, `let` or `var` initializer cannot be built, the names it would bind were left undefined, so
every later use of one of them reached `buildRefPath` and was counted as `a name that is not a local`. The
census therefore reported the consequence of one unbuildable construct once per use: 2136 sites in the
compiler against 1314 unbuilt bodies, and 27 in the stdlib programs. The kind that dwarfed the rest was
not a kind of construct at all, and the real roots were hidden under it.

## Decision

`buildLocal` poisons the names of a binding that failed: a pattern's names (`patBoundNames`), a `let`'s,
a `var`'s. A poisoned name is a scope entry with a negative `LocalId`; a use of it (in an expression or as an
assignment place) fails the body without counting a kind of its own. The failed initializer is still
counted, and the body still does not build.

## Measured

`scripts/ci/tir-census.sh --wide`, compiler area, on top of D568: `a name that is not a local` 2136 -> 2.
Bodies built are unchanged (11114 of 12428; stdlib programs 1084 of 1165, I0003 0 in the stdlib), because
the bodies that failed still fail; what changed is that the census now names their roots. The largest
are `an operator on a declared type` 183, `a default argument that is not a literal or a name` 124, `a call
whose named arguments reorder effects` 103, `a member access that is not a record field` 72, `a call the
checker did not resolve` 53, `a branch conversion` 40, `an extern call no host overload fits` 39.
