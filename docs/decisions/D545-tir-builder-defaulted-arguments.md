# D545 - Defaulted arguments in the TIR builder (docs/70 phase 3a, #8613)

**Status:** shipped; extends D544.

## Context

`a defaulted argument` was the second-largest I0002 kind (70). docs/70 section 6.2
puts a call's arguments in TIR "with defaults filled in", but the resolved signature
carried only `hasDefault`, and a parameter's default expression was never numbered
(`renumberNodeIds` skipped function parameters), so the checker could not record its
type.

## Decision

1. `ResolvedParam` gains `dfltExpr: Option[Expr]`, the default as written, set from the
   declaration (`None` for a signature read from a restored package).
2. `renumberNodeIds` numbers parameter defaults: `AstMapper` has a `params` flag
   (default false, set by `mapFileNodes` only) that maps each function parameter's
   default. Other mappers (contract rewriting, desugaring) are unchanged.
3. A call that leaves out a defaulted parameter places the default at the call under a
   fresh `NodeId` (the declaration's own node stays the parameter's), converted to the
   parameter's type. A default that is a literal or a name the checker resolved to a
   declaration (a constant, a nullary case) builds; any other default, and a default
   from a restored package, stays counted as I0002 until the builder can renumber a
   whole sub-tree, so a default is never built under the declaration's node id twice.
4. The name case is shared with the ordinary `EPath` arm (`buildRefPath`), and the
   default never goes through the caller's local scope, so a caller's local of the same
   name as a constant the default names cannot capture it.

## Tests

`tir_build_self_test.l`: a literal default, a constant default used by two calls (their
placed defaults verify, so their node ids are distinct), a computed default that stays
counted, and the older test for a literal default now expecting it to build. Record
construction defaults stay counted under the same kind.
