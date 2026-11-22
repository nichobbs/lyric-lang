# `Alias.Type.f(x)` resolves through an import alias and a `pub use` chain (docs/70 phase 3a, #8613)

**Status:** shipped; checker.

## Context

`import Pu as L` and `L.Config.describe(c)`, where `Pu` re-exports `Pu.Client` (`pub use`) which declares `func Config.describe(c: in Config)`: the checker looked for the dot-named function in a package named `L`, so the call stayed untyped and the TIR gate (D347) stopped the body (`Pu.Main::main` of `llvm_project_self_test.l`).

## Decision

The qualifier of a package-qualified dot-named call names the declaring package when it is that package, an import alias of it, or a package that re-exports it, transitively (`qualifierDeclares`, over `symTablePackageOfAlias` and `symTableReexportClosure`). Candidates are filtered by that rule in `dotSigInPackage` and `anyTypedDotCandidate`.

## Results

`llvm_project_self_test.l` (50 of 50 on native): the `Pu` facade project builds.
