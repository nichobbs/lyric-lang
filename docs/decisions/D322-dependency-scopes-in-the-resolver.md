# D322 - A dependency's signatures resolve in the scope its own imports make; `tryFindOneCore` is deleted (docs/70 phase 2c, #8612)

**Status:** shipped. Step 8 of docs/70 §13 phase 2c, after D318.

## Context

After D318 the resolver answered every bare-name question for the checked
package. A dependency's signatures still resolved through the checker's own
scan (`tryFindOneCore`): its own package first, then a package it imports,
then a package reachable through its imports' imports, then any symbol of that
name. Nothing stopped a dependency's signature naming a package it never
imported, and a dependency's alias (`import Std.Tls as Tls`) was honoured by
accident of that scan rather than by a scope.

## Decision

1. **A dependency has a scope.** `ImportedPackage.importDecls` carries the
   package's imports as declared (path, selector, alias, `pub use`), and
   `DepPackage.imports` hands them to `Lyric.Resolve`, whose
   `ResolverContext.depScopes` holds one `FileScope` per dependency, built like
   a file of the checked package. Bridges that have the parsed source (MSIL
   stdlib and project packages, JVM, native, LSP) pass the declarations.
2. **Legacy forms keep a meaning.** A package known by name only (a restored
   package: the synthesised surface keeps only the imports its declarations
   need, and contract metadata records `imports`, `wholeImports`,
   `selectedImports`, `reexports`, but not aliases) has its `imports` names read
   as whole imports. That is the superset of what it could import, so a
   dependency built before this change keeps resolving. Restored metadata gains
   no new key in this step: phase 5's interface artifact replaces the
   synthesised surface, and a new key would be dead after it.
3. **The rule is §4.3's.** A bare name in a dependency's signature resolves
   through the dependency's own package, then what it imports, then the
   prelude. A name no scope resolves falls back to a package-less symbol (a
   built-in or an `import extern` binding), as for the checked package. A
   dotted path in a dependency's signature (`Tls.TlsServerConfig`, written
   through an alias the dependency's own build rewrote) resolves through
   `resolvePath` in that scope (`symTableDepPath`).
4. **Deleted:** `tryFindOneCore`, its `reachableOnce` walk, and the third tier
   of "any symbol of that name". What remains of the old lookup is
   `newestSymbolNamed`, used only when no scope judges the lookup (a
   synthesised contract surface, or no package being checked).

## Census (docs/70 §12.2)

The rule rejects code that compiled before, so it was measured first, with the
new lookup behind an environment switch and the old one the default: the
compiler, stdlib and ecosystem bundle builds, `lyric check --manifest` over
every one of the 98 `lyric.toml` files, and `lyric check` over the 100
`lyric-stdlib/tests/*.l` files, once in each mode. The error lines of the two
runs were identical except for a build-order artifact. The first strict
bundle build found three dependencies whose signatures wrote an alias-qualified
type (`Tls.TlsServerConfig`, `RxKernel.Regex`, `Tls.Certificate`); the
`resolvePath` rule above resolves them. No source needed migrating, so there
is no separate migration step.

## Consequences

- A dependency naming a package it does not import is `T0211` (its surface does
  not resolve), reported once per package.
- The checker has one scope-aware lookup for both the checked package and its
  dependencies. The remaining program-wide lookups are `symTableTryFindAllNamed`
  and kin (#8722).

## Verification

`typechecker_self_test`: a dependency's aliased import qualifies its signature
types; a dependency's bare name needs its own import (T0211). The census above,
the compiler and stdlib bundle builds, and the verification set of the PR.
