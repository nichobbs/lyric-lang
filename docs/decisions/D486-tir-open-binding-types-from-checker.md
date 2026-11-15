# D486 - A binding, scrutinee or pattern the checker left open takes the type the checker resolved from its uses (docs/70 phase 3a, #8613)

**Status:** shipped; extends D483.

## Context

`val o = None`, `val t = (None, 5)` and `match (None, 5) { ... }` leave a type argument open where they are written; a later use fixes it. The checker already resolves these (`resolveOpenBindingSites`, #7788, #7887, #7863) and records the result as a source type, `SymbolTable.localBindingTypeSites`, for `Lyric.Mono`. It records `<error>` for the nodes themselves (the initializer, later reads of the name, the patterns over it), so the builder found no usable type and counted the body, and a name a pattern binds from the open type (`case Some(v) -> v`) then failed as "a name that is not a local".

## Decision

- `buildInit` reads `localBindingTypeSites` at the initializer's span when a binding has no annotation, and settles the initializer to it. A tuple initializer settles its elements to the tuple's element types.
- `buildMatch` does the same for a scrutinee, before building it.
- A read of a local the checker left untyped takes the type the local was declared at (`openLocalTy`).
- A scrutinee's type fixes each pattern over it (`settlePattern`): a tuple pattern's elements take the tuple's, a constructor pattern's arguments the case's payload types at the union's arguments; `val` of a pattern settles from its initializer.

## Results

`tir-builder-shapes-e2e.sh` gains `open_binding_uses` (alias of an open `None`, an open tuple, patterns over both; exit 8). `expected_type_propagation_self_test.l` builds 62 of 68 bodies. Still open: an open tuple whose element type only a later `val (xs, n) = t` store fixes (the checker records those through the pattern's own sites, not the tuple's), `tupleReassigned`-style tuple locals, and generic functions over them.
