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

## Measured

`scripts/ci/tir-census.sh` over the 98 programs: bodies built 964 -> 965 of 1165,
I0003 0. `a defaulted argument` is 76 (it was 70; bodies that now get past an earlier
failure reach it), so the literal and constant defaults of same-package functions
were a small part of it. What remains under the kind is the default of a record
construction field and the default of an imported function. A restored package's
signature carries no default expression until the checked package interface (docs/70
phase 4) holds defaults as TIR expressions (section 7.2), so the imported case is
phase 4's, not this builder's; the construction case (the record's `FieldDecl`
default, same package) is the next slice. Next by count: a defaulted argument (76),
a name that is not a local (75), a method, constructor or member call (58), a method
call with no declared receiver (39), a function with no symbol (37), an argument
conversion (34).
