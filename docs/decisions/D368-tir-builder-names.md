# D368 - The builder's names that are not locals: `refByNode` (docs/70 phase 3a, #8613)

**Status:** shipped (`SymbolTable.refByNode`, `recordRefNode`, the `EPath` case of `buildExpr`); extends D367.

## Context

After D367 the largest uncovered kind in the builder census was a name that is
not a local (720 nodes over the stdlib tests): a module-level `val` or `const`,
a union or enum case used as a value, a function used as a value.

## Decision

1. `SymbolTable.refByNode: Map[Int, RefSite]` is keyed by the name expression's
   `NodeId`. `RefSite` is a `SymbolId` (the DefPath the resolver interns, or the
   key it would intern for a dependency's declaration) and a `RefKind`:
   `RkValue` (a `val` or `const`), `RkNullaryCase` (a union case with no fields,
   or an enum case) or `RkFunc` (a non-generic function used as a value).
2. The checker records it in `resolveExprPath` where the name resolves: bare and
   package-qualified vals and consts, bare and package-qualified cases, and a
   bare function value that is not a callee. An enum case several enums share
   is not recorded (the checker leaves it unresolved without an expected type),
   nor is a case with a payload (a constructor, built by the call that gives it
   its fields), nor a generic function (its type arguments wait for the generic
   call step), nor a package-qualified function value.
3. `buildExpr` makes `XConstruct(sym, [])` of a nullary case and
   `XGlobal(sym, [])` of a value or function. A name with no entry stays an I0002.
4. `caseSymbolId` is the one place a union or enum case becomes a `SymbolId`;
   `recordCtorCalleeNode` uses it too.
5. Known limit: a bare generic nullary case (`None`, `Nothing`) is typed with an
   unsolved type argument, which the checker fixes from the expected type only
   after the expression is recorded, so the builder reports it as an I0002
   (`tir_build_self_test.l` pins this). Recording the expected-type solution
   comes with the generic-call step.
