# D388 - The builder's record and union-case constructions (docs/70 phase 3a, #8613)

**Status:** shipped (`buildConstructCall`, `buildCallArgs` in `build_expr.l`); extends D369.

## Context

After D369 a call that built a record or a union case (`P(x = 1, y = 2)`,
`A(n = 3)`) was an I0002 ("a method, constructor or member call"): the checker
recorded the constructed type's `SymbolId` (`calleeByNode`, D361) but nothing
about its fields.

## Decision

1. `SymbolTable.ctorSigByNode: Map[Int, ResolvedSignature]` holds the fields of
   a non-generic record or union-case construction as the parameters of a
   signature (field name, type, whether it has a default), keyed by the call's
   `NodeId`. A positional union field is named `#<index>`. It is recorded where
   `calleeByNode` is, at the three construction sites (bare case, bare record,
   expected-type case). A generic construction (the result type has type
   arguments, or the record declares generics) is not recorded: it waits for the
   generic-call step.
2. The builder reuses the argument placement of a function call: `buildCallArgs`
   places positional and named arguments by parameter, refuses reordering that
   would reorder effects, widens an `Int` argument to a `Long` field, and counts
   a missing or defaulted argument. `buildDirectCall` wraps its result in
   `XCall`; `buildConstructCall` unwraps the `TArgIn`s into `XConstruct(sym,
   fields)` with the fields in declaration order.
3. Not built yet, counted as before: constructions of opaque and exposed
   records, generic constructions, and a field left to its default (the default
   expression is checked elsewhere and carries no recorded type).
