# D550 - The TIR census names where each uncovered kind was first met (docs/70 phase 3a, #8613)

**Status:** shipped; extends D542 and D544-D547.

## Context

The census counted the kinds the builder has no case for (`a method, constructor or
member call x 58`) but not where they are, and most counts in a body are cascades of one
earlier refusal (a binding the builder could not build leaves its name undeclared, so every
later read is `a name that is not a local`). Finding the real shape behind a kind meant
guessing at programs or rebuilding the compiler with a temporary patch.

## Decision

1. `BuildEnv.sites` and `BuildCensus.sites` remember, per kind, the `line:column` where it
   was first met in the function (`noteUncoveredAt`, used by `uncoveredExpr`,
   `uncoveredPat` and `uncoveredStmt`); the build census lines read
   `kind x N (first at L:C)`.
2. `scripts/ci/tir-census.sh` keeps the first site per kind across files and prints it as
   `I0002 kind K: N (e.g. file:L:C)`, and still parses the older line shape.

## What the sites showed (stdlib census, 965 of 1165 bodies built, I0003 0)

- `a call the checker did not resolve` (24): `Console.println(...)` and its aliases. The
  checker types a qualified call of a codegen built-in name (`println`) through
  `qualifiedBuiltinCalleeType` and records neither `builtinByNode` (that table is filled
  only for a single-segment name) nor a callee, so the builder has nothing to build. The fix
  is in the checker's qualified built-in path, not the builder.
- `a method call with no declared receiver` (39): protected-type entry calls
  (`t.add(n)` on a `protected type`), whose signature has no `recvMode`.
- `a method, constructor or member call` (58): a call the checker recorded a callee for but
  not as a construction, method or extern site (a protected type constructed with `Total()`
  is the first sample).
- `a name that is not a local` (75) never appears as a body's first error: it is the
  cascade, and falls as the root kinds are built.

## Tests

`tir_build_self_test.l`: an uncovered kind records the line of its first site.
