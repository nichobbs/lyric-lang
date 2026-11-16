# D611 - `Self` inside a record or protected type member is the owner type in the TIR (docs/70 phase 3a, #8613)

**Status:** shipped; extends D476.

## Context

D476 made `Self` in an `impl` member convert to the impl's target type. A method declared inside a record (`func inc(self: inout Self): Unit`, `func copyOf(self: in Self): Self`) or a protected type spells `Self` the same way, and the self-tests census still reported about 75 first errors "no usable type for `Self` outside an interface" for such members (`Counter.inc`, `Rect.area`, `Accumulator.add`, ...).

## Decision

`buildMemberWith` pushes the type a member belongs to for every member site, not only an `impl` member: the site's receiver type, or `genericRecvOf` for a member of a generic owner, so `Self` in the declared parameter and result types and in expression types converts to it.

## Not covered

`Self` in an interface default body keeps `TyConvCtx.selfIface`, which nothing sets yet (interface bodies are not built).
