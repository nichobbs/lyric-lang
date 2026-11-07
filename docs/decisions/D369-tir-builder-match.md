# D369 - The builder's `match` and patterns (docs/70 phase 3a, #8613)

**Status:** shipped (`buildMatch`, `buildPat` in `build_expr.l`); extends D368.

## Context

After D368 the next kind in the builder census was `match` (484 nodes) with its
patterns, which also gates `for` loops and binding patterns.

## Decision

1. Four tables in `SymbolTable`, keyed by `NodeId`, filled in `bindPatternTyped`
   and `inferMatchExprCore`:
   - `patTypes`: the type each pattern is matched at (a binding's local has
     this type; a payload pattern reads its field type from it).
   - `patSymByNode`: the `SymbolId` of the union or enum case a constructor or
     bare-case pattern resolved to, or of the record type a record pattern named.
   - `patBindingNodes`: the `PBinding`s the checker bound as locals rather than
     read as bare case names, so the builder never has to repeat that rule.
   - `matchExhaustive`: whether the arms are proved to cover every value.
2. `exhaustive` in `XMatch` is only ever a proof. It is true when the existing
   exhaustiveness check added no diagnostic and either an arm is a catch-all or
   every case of a finite-case scrutinee is named by an unguarded arm whose
   payload patterns match anything. The existing check looks at case names, not
   payloads, so `case A(1)` alone does not prove `A` covered. `false` says
   nothing was proved, never that a case is missing, so a backend keeps its
   fall-through trap; this is the safe direction.
3. Built: wildcard, literal, tuple, parenthesised, binding (with `x @ pat`),
   constructor and bare-case patterns, record patterns with named fields.
   Counted as I0002 and not built: or-patterns (the alternatives must share
   `LocalId`s), range, type-test and constant patterns, shorthand record fields,
   and a pattern the checker did not resolve.
