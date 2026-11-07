# D394 - The builder's generic calls (docs/70 phase 3a, #8613)

**Status:** shipped (`buildDirectCall` in `build_expr.l`); extends D367 and D388.

## Context

A call to a generic function was an I0002 ("a generic call"). The checker
solves the callee's type arguments but kept them only as source-spelled
`TypeExpr`s keyed by the callee's span (`genericCallTypeArgSites`, for
`Lyric.Mono`), which the builder cannot use without re-resolving names.

## Decision

1. `SymbolTable.genericArgsByNode: Map[Int, List[Type]]` holds the type
   arguments of the generic call at a `NodeId`, one per generic of the callee in
   order. `recordGenericCallTypeArgs` takes the call's `NodeId` (0 for the two
   dot-named routes that have no call node) and records before its span checks,
   so a generated call with a node id is recorded too. A call with a value
   generic parameter, or with an argument that is neither closed nor made only of
   the enclosing function's own type parameters, clears the entry (a later
   resolution of the same node replaces an earlier one).
2. `buildDirectCall` converts the recorded types to `Ty`, substitutes them into
   the callee's parameter types (`substituteTyParamsOwned` over `generics` and
   `genericOwners`), places and converts the arguments against the substituted
   signature as for a non-generic call, and emits `Direct(sym, typeArgs)`.
3. Counted, not guessed: a generic call with no recorded instantiation or a
   count that differs from the callee's generics, and every generic call inside a
   generic function (the function's own binder is not registered yet; generic
   function bodies are the next slice). Generic constructions, generic methods
   and the bare generic nullary case (`None`) still wait on the same table and
   on `ctorSigByNode`/`methodCallByNode` covering generics.
