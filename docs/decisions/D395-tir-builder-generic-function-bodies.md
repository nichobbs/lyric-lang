# D395 - The builder's generic function bodies (docs/70 phase 3a, #8613)

**Status:** shipped (`buildFnBody` in `build_expr.l`); extends D394.

## Context

`buildFnBody` refused any generic function ("a generic function"), so a generic
call inside one could never reach D394's `genericArgsByNode` conversion: a
`TyParam(name, owner)` converts only through a registered binder
(`tyConvBind`), which nothing registered outside tests.

## Decision

1. `symTableFuncSymOf(tbl, fn)` gives the resolver's `SymbolId` of a top-level
   function: the symbol of its name whose declaration is at the function's span.
   `extractGenericNames` is public so the builder lists the generics (type and
   value) in the order the checker's signature does.
2. `buildFnBody` binds the function's own generics: `tyConvBind(ctx, fn.name, sym,
   names)` (the checker's owner key for a top-level function is its name) and a
   `GenericContext` for resolving the parameter annotations. A type parameter
   converts to `TParam(sym, index)`; a function with no symbol in the table is
   counted ("a generic function with no symbol").
3. Not built yet: generic methods and generic type declarations' members (their
   owner keys are `impl@...`/`Type.method`; `buildCensus` walks top-level
   functions only), and bounds.
