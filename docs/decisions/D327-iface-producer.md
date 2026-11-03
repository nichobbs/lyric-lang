# D327 - The interface producer: `Lyric.IfaceBuild` builds a package's `Iface` from its checked source (docs/70 phase 5a, #8615)

**Status:** shipped (producer only). Third slice of phase 5a, after D321 and
D324. Format version 3. Embedding in DLL, JAR and native outputs, the round-trip
validation (I0005) and T0213 follow.

## Context

D321 and D324 define the interface model and its canonical codec. Nothing yet
builds one from a package. docs/70 §9.2 wants the checked, resolved surface, so
the producer reads the checked source and the checker's own answers rather than
re-resolving names.

## Decision

1. **`Lyric.IfaceBuild`** (`lyric-compiler/lyric/iface_build/`):
   `buildIface(res: CheckResult, builtAgainst, targets)` returns the package's
   `Iface` or the list of declarations whose types it could not record. It walks
   the checked file's items the way `Lyric.Resolve` registers them and takes
   DefPaths from the resolver's own helpers (`funcDefPath`, `methodDefPath`,
   `typeDefPath`, `memberDefPath`), so an interface and the resolver's table
   agree on what a package declares (the self-test asserts it).
2. **Types** are the checker's: each written type is resolved by the checker's
   `resolveType` against the package's symbol table, then converted to `Ty`
   (`ifacebuild_conv.l`). `TyUser` becomes `TNamed` (ids are DefPath-interned, so
   the same id the checker used), an extern type's `extern::<host>` path becomes
   `TExtern`, and `TyVar` and `TySelf` become `TParam(owner, index)` with the
   owner and index taken from the declaration's generic parameter list (a
   method's frames nest under its type's). A type the interface cannot record
   (the checker's error type, `Self` outside an interface, an undeclared
   parameter) is a build error that names the declaration; nothing is
   substituted.
3. **Constraint bounds.** A `where` constraint that names an interface is a
   `TNamed` of that interface. A marker constraint with no declaration (a derive
   marker) is `TNamed` of the DefPath `marker::<name>`, interned like any other
   path, so `Ty` needs no new case.
4. **What is recorded.** `pub` and `internal` declarations, extern types always
   (they are host bindings visible to every package), and the members of those
   declarations: record and protected-type methods, interface members, union and
   enum cases, `func Type.method` functions. A range subtype's bounds are a
   `TRefined` of its underlying type; bounds must be integer literals. A
   constant or `val` records a plain literal initialiser as its value.
5. **Header.** The package name, the file-level verification level (new
   `IfAxiom` for `@axiom`, so format version 3), `@pure`/`@io` file annotations,
   re-exports (`pub use`), the caller's target set, and the interfaces built
   against (empty until dependencies ship interfaces). A function's level is the
   package's unless it is `@axiom` (the only per-function level the language
   has), so `IfDFunc` carries `isAxiom` and no separate level.
6. **Pipeline hook.** `MiddleEndOptions.buildInterface` makes `pipeCheckAndMono`
   build the interface from the type-checked file into `interfaceOut`. It is off
   by default; the embedding slice turns it on.
7. **Not recorded yet, no placeholder fields:** default values, contracts, bodies
   and invariants (the 3a TIR builder); associated types of interfaces;
   `extern package` members; a `val` or `const` initialiser that is not a plain
   literal has no recorded value; a `pub val` needs a written type. The linkage
   table and hidden exports are 5b. A build error names each such declaration
   where it would otherwise lose type information.

## Consequences

- The converter file imports `Lyric.Tir` and `Lyric.TypeChecker` but not
  `Lyric.Parser`, whose type-expression constructors (`TTuple`, `TArray`, ...)
  share names with `Ty`; the walker imports `Lyric.Tir` selectively.
- The census over the stdlib and the ecosystem libraries happens in the embedding
  slice, before any build fails on a producer error.
