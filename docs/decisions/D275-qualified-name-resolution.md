# D275 — Qualified names resolve through re-exports; module vals hide imports in calls; explicit alias type arguments (#7799, #8350, #8562, #7368)

**Status:** shipped

## Context

Four resolution defects shared a cause: the rules of docs/01 §9.2 were applied
to bare names and types but not uniformly to qualified calls, to calls of
function-typed values, or to explicit type arguments.

- `import Std.Collections as Coll` then `Coll.newList()` was "unknown name":
  the bare name reached `newList` through `Std.Collections`'s own import of
  `Std.CollectionsHost`, the qualified spelling did not (#7799).
- `Std.CollectionsHost.newList()` with only `Std.Collections` imported passed
  the checker (transitive reachability) and failed on MSIL with T0115 while the
  JVM accepted it (#7799).
- A module-level `val` of function type lost a bare call to an imported
  function of the same name, silently calling the import (#8350).
- T0123 for a qualified function value gave overload advice when the cause was
  an ambiguous qualifier (#7368).
- `sum2[Count](1, 2)` with `alias Count = Int` was M0002: the explicit index
  was never run through alias resolution (#8562).

## Decision

1. A package's qualified names include what it re-exports from its own
   imports; its own declaration wins over a re-exported one.
2. A package-qualified expression (value or call) must name a package the file
   imports directly (T0020 with `add import`). Types and pattern heads keep the
   transitive reachability test. Both targets now agree.
3. A module-level `val`/`const` in scope hides an imported function in a bare
   call, as locals and parameters already did.
4. T0123 on a qualified function value distinguishes "ambiguous qualifier"
   (names the matching packages, advises the full path) from "overloaded
   function" (lambda advice).
5. Explicit type arguments written as the index of a call (`f[Count](...)`) are
   alias-resolved with the other type positions.

#7217 and #7970 were verified as already fixed on `main` (a bare unimported or
alias-only name is T0020 in single-file and project builds). #7214 (a `pub`
signature naming a package-private type) stays a lint (L007), see the progress
entry.
