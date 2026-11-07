# D344 - Alias targets come from the resolver (docs/70 phase 2d, #8752)

**Status:** shipped for the alias table the passes read; the `AliasRewriter`
tree walk, `TypeAliasResolve` and the backends' own alias layers remain
(see Consequences).

## Context

Three places scanned declarations for `alias X = T` on their own:
`TypeAliasResolve.projectAliasTargets`, `BareFuncRef.collectFuncAliasTargets`
and `Pipeline.canonicalAliasDotNamed`. Each keyed the table by simple name and
read the target as written, so a target that names its type through a renamed
import (`import A.Two as T`, `alias Pick = T.Seed`) lost the package: the
dot-call rewrite reduced `Pick.base()` to `Seed.base()` and the checker bound
the first `Seed` the file imports (package One's), on both backends (#8752).

## Decision

1. `Decl` for `SKAlias` carries its target (`aliasTarget`); it is absent for a
   parameterized alias and for one whose target is a type of its own name (the
   stdlib's `pub alias Random = <extern Random>`), which no pass substitutes.
2. `Lyric.Resolve.aliasTargetsFor(ctx, scope)` returns the table a file sees:
   its package's aliases, then the `pub` aliases of the packages it reaches by
   import, selective import (under its rename), or re-export, the first of a
   name winning. A target comes back with its names qualified in the scope that
   declares it: a head renamed by `import P as T` and a name renamed by
   `import P.{X as S}` are spelled out as `P.<name>`.
3. `projectAliasTargets` reads it (merged over the package's files, as the pass
   rewrites a whole package), and `canonicalAliasDotNamed` uses that table and
   rewrites a bare alias head in a call to the target's qualified path, so
   `Pick.base()` becomes `AliasRen.Two.Seed.base()`, which the checker already
   binds through the type's package (#8179).

## Consequences

- `emitter_project_self_test.l` runs the #8752 program on MSIL and JVM
  (expected `2`, was `1`); `resolve_self_test.l` covers the table.
- Not done here: the `AliasRewriter` tree walk and `TypeAliasResolve` are still
  read by the checker, MSIL, JVM, native and the language server, and the
  backends keep `cctx.aliasTargets` / `FuncCtx.aliasTargets` for restored
  dependencies, which no source reaches. Deleting them needs the backends to
  receive resolved types, which is the typed IR's job (docs/70 §13 phase 4).
