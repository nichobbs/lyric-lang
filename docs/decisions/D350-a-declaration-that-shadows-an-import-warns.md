# D350 - A declaration that shadows an import is W0037 (docs/70 phase 3a, #8767)

**Status:** warning step in progress; the census decides whether it stays a
warning.

## Context

docs/70 §4.3 resolves a bare name to a declaration of the package (step 2)
before a name the file imports (step 3), so a package-local `func f` hides an
imported `f` and every call of `f` in a file that imports it binds to the local
one. The rule is deliberate (D141's own-package-first tier, §4.3), but it is
silent: #8767 found a package-local `exprKindTag` rebinding two existing calls
of `Lyric.Parser.exprKindTag` with no diagnostic.

## Decision

1. The rule stays: the package's own declaration wins, and two imports of one
   name remain T0123.
2. **W0037** is reported at a top-level declaration of the package (function,
   type or module value) that hides a name some file of the package imports
   directly, of the same kind: "'f' declared here shadows the 'f' this package
   imports from 'P' (import P); calls of 'f' in files that import P bind to
   this declaration". A name reached only through a re-export, a prelude name
   and a member or case are not compared. One warning per declaration name.
3. The check lives in `Lyric.Resolve` (`shadowedImports`, `resolve_shadow.l`),
   where both the declaration table and each file's import scope are known; the
   checker reports it beside its other declaration-level warnings.
4. Order: warning, census over the compiler, stdlib and ecosystem (CI's job
   logs are the complete census), then decide whether intentional shadowing
   needs an opt-out before it could become an error. It is not made an error in
   this entry.
