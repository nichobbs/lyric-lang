# D559 - The builder builds defer, try, scope and binding-free or-patterns (docs/70 phase 3a, #8613)

**Status:** shipped; extends D366 and D369.

## Context

`Lyric.Tir` has `TsDefer`, `TsTry`, `TsScope` and `TpOr`, but the builder counted each use as an
uncovered kind (`a defer` 7, `a try statement` 6, `a scope` 3, `an or-pattern` 1 over the stdlib
census), so any function containing one never built.

## Decision

- `defer { ... }` is `TsDefer` over its block; `try { ... } catch T { ... } finally { ... }` is
  `TsTry` over its blocks with each catch's exception type name; `scope { ... }` is `TsScope`.
- A `catch` that binds the exception, and a `scope` that binds its handle, are still counted
  (`a try statement with a catch binding`, `a scope with a handle binding`): the TIR needs a `Ty`
  for the binding and neither the exception type name nor the scope handle has one yet.
- An or-pattern is `TpOr` over its built alternatives when no alternative binds a name. Every
  alternative of a TIR or-pattern binds the same locals and a local is declared once, so an
  or-pattern that binds a name is still counted (`an or-pattern that binds a name`) until locals can
  be shared between alternatives.

## Measured

See the progress entry.
