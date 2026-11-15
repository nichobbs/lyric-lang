# D476 - `Self` inside an `impl` member is the impl's target type in the TIR (docs/70 §6.2, #8613)

**Status:** shipped.

## Context

An `impl` member may spell its receiver or result `Self`, mirroring the interface (`func cl(self: in Self): Self`; the checker substitutes the impl's target for it, #6417). The builder's type conversion knew `Self` only inside an interface (`TyConvCtx.selfIface`, which nothing sets), so every such member recorded I0002 "no usable type for `Self` outside an interface": 127 hits in the wide census (main builder part 10).

## Decision

`TyConvCtx.implSelf` is a one-element stack of the type `Self` names; `buildMemberWith` pushes the impl's target type (the site's receiver, or `genericRecvOf` for a member of a generic impl) while it builds an impl member and pops it after, so the declared parameter and result types and every expression type convert. Outside an interface or an impl the message now says so.

## Not covered

`Self` in an interface default body keeps `selfIface` (unset today; interface bodies are not built yet).
