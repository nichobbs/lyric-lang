# D-progress-943 — Imported generics: qualified calls, origin-scoped bodies, and qualifier resolution

**Status:** shipped

## Problem

A generic function has no callable form in its declaring package's DLL: every
call site specialises a concrete copy of its body into the *calling* package
(`Lyric.Mono.monoFileWithImports`, contract metadata carrying the body since
#6363). Four gaps made that unusable for a generic-heavy library consumed
from another package:

1. **Qualified calls were not specialised properly.** `Diff.diff(a, b)` or
   `Session.start(p, init)` took a separate, weaker last-segment path (no
   lambda or constructor evidence, no imported-generic fallback), and
   `Pkg.f[T](args)` was never recognised at all: it type-checked and then
   failed at codegen with T0115. Two packages' same-named generics could
   also collide, since generics were keyed by bare name only.
2. **A specialised body resolved names in the wrong scope.** The copy is
   compiled into the caller, so a bare call in the body (`twice(n)`, where
   the declaring package imports `twice`) was resolved against the
   *caller's* imports and failed with T0123 unless the caller happened to
   import the same package.
3. **Qualifiers only matched full package paths.** With `import Ui.Widgets`,
   the type checker looked for a package literally named `Widgets`, found
   none, and fell back to bare-name resolution, so `Widgets.field(...)`
   resolved to `Forms.field` from another imported package (a wrong-type
   T0043 or, worse, a silent wrong call). MSIL codegen had the same shape:
   a qualified call searched every import by bare name.
4. **A failure inside a specialised body gave no clue why.** It surfaced as
   a generic T0123 naming only the consumer's package.

## Decision

- **Origin package.** Every generic collected for specialisation is tagged
  with the reserved annotation `__lyric_origin("<package>")`
  (`Lyric.Mono.withOriginPkgMono`; reader `Lyric.Parser.originPkgOf`), and
  the specialised copy keeps it. The restored-artifact collector now passes
  the artifact's package name instead of "".
- **Qualified calls in `Lyric.Mono`.** `buildQualifiedGenNames` maps every
  qualifier the file's imports make valid for the declaring package (full
  path, `as` alias, last segment) plus the function name to the bare name
  the generic is registered under. When the bare name already resolves to
  that declaration, it is used directly; otherwise a synthetic
  `<name>__in__<Pkg_Path>` alias is registered, so same-named generics from
  different packages never collide. `Pkg.f(...)` and `Pkg.f[T](...)` are
  rewritten to the bare form and take the full single-segment inference and
  specialisation path. The old last-segment arm remains only for generics
  without a recorded origin.
- **Origin-scoped resolution in MSIL codegen.** `FuncCtx.originPkg` is set
  from the annotation, and `originScopedFqnMsil` resolves a bare callee in a
  specialised copy against the declaring package first, then that package's
  imports, before the calling package's own tiers.
- **Contract imports.** `Contract` gains `imports: List[String]` (the
  package's own non-extern imports), written as an optional `"imports"` JSON
  array and read as empty when absent, so older contracts still parse.
  Restored packages' imports are registered in `cctx.pkgImports` so the
  origin scope works across a compiled-package boundary.
- **Qualifier matching.** `findDirectSig` (type checker) accepts a qualifier
  that is the full package path or its trailing segment(s)
  (`pkgMatchesQualifier`). Once any candidate from the named package exists,
  the call binds to that package, so an argument mismatch is reported
  against its signature instead of re-resolving to another package. MSIL
  codegen restricts a qualified call's import search to the imports the
  qualifier names (`importsMatchingQualifierMsil`), falling back to the
  previous search only when no import matches.
- **Diagnostic.** An unresolvable callee inside a specialised copy now
  reports T0123 naming the generic, its declaring package and the calling
  package, and states the rule: every function a generic body calls must be
  `pub` in the declaring package or in a package it imports.

## Scope and follow-up

A generic body that calls a **non-`pub`** helper of its own package still
cannot be specialised in another package: the helper has no public symbol to
bind to across the assembly boundary. The new T0123 text says so. The fuller
fix, where such helpers stay private at the source level but are emitted as
ABI-visible and listed in contract metadata (the `@usableFromInline` model),
is tracked separately.

## Verification

A cross-package repro project (a library of generic helpers plus a
`@test_module` consumer) exercises qualified calls, qualified explicit type
application, a body calling its package's import, and qualifier
last-segment resolution. The type-checker cases are in
`typechecker_self_test.l`.
