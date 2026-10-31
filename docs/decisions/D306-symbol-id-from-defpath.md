# D306 - A type's identity is its DefPath (docs/70 phase 2b, #8612)

**Status:** shipped. Implements the type part of docs/70 §13 phase 2b
(D267, §4.2).

## Context

The type checker identified a user-defined type by a `TypeId` drawn from a
per-check counter, one per registration. A package registered twice in one
check (reached both as a restored dependency and from source, or a stdlib
self-build whose sources are also the base packages) gave each of its types
two ids. Every site that compared types or looked one up had to land on the
same registration:
- #1435 kept the stdlib out of the in-bundle closure;
- #2394 deduplicated extern types by host name;
- 36d2734 (#8589) made a qualified type scan newest-first to match its
  constructor.

docs/70 §4.2 replaces `TypeId` with a `SymbolId` interned from a stable
`DefPath`.

## Decision

1. **`SymbolId` replaces `TypeId`** throughout the type checker (`DeclKind`,
   `TyUser`, the conformance and impl tables, the LSP). `typeIdEq` is
   `symbolIdEq`.
2. **A type's id is its interned DefPath.** `DefPath` is a package plus a
   path, rendered with `::`. A type is `Pkg::Name`; an extern type bound to
   a host type is `extern::<host name>`. `symTableInternDefPath` gives every
   registration of one DefPath the same id, dense from 1.
   `symTableDefPathKeyOf` maps an id back to its key.
3. **No package, no DefPath.** A declaration registered with no package (the
   checker's flat `checkWithImports` form) has no stable path and gets a
   fresh id, as before. The built-in `Task[T]` and `buffer[T]` keep their
   reserved negative ids.
4. **The per-check counter is deleted** (`TypeIdCounter`, `freshTypeId`), and
   so is the extern-type deduplication scan (`findExternTypeIdByClr`), which
   the `extern::` DefPath subsumes.
5. **A package is not its own import.** A project build hands the checker
   every project package as an import, the one being checked included
   (#7583), so that package's types were registered twice: as its own and
   as imported. With distinct ids the import registration was unreachable
   from inside the package. With one id, the scans that take the first
   symbol of an id picked it, and a `.copy` inside the package was lowered
   to a qualified constructor, which is invalid IL. ILVerify found 12 such
   methods in the compiler bundle. `checkWithImportedPackagesCore` now drops
   the package being checked from its imports (`withoutOwnPackage`), and
   `symTableTypeSymbolOf` returns an id's newest registration, the one
   name lookups pick.
6. **Functions, values and locals are not in this step.** Overloaded
   functions need a discriminator in their DefPath, and nothing consumes
   their ids until the resolver (phase 2c) does, so their DefPaths are
   defined there. `LocalId` comes with TIR (phase 3a), which binds locals.

## Consequences

- Two registrations of one type are the same type wherever they meet. The
  newest-first scans and #1435's guard stay; they now keep duplicates out
  of lookups and the symbol table rather than keeping two ids apart.
- No language-level change: no syntax or output changes.
- One diagnostic moves. A project package whose own signature names a
  missing type is reported at that signature (`T0010` in `lib.l`) when the
  dotnet project build checks it. Before, the package was among its own
  imports and was reported as a dependency of itself (`T0211`). The JVM
  project build checks the consumer first and still reports `T0211`
  against the consumer. The compile-fail corpus accepts either code for
  that case (`expect` lines may now list alternatives).

## Verification

`typechecker_self_test`:
- a type registered twice has one id, whose key is `Lib.Build::Choice`, and
  another type has another id;
- extern types share an id by host name and not with a same-named Lyric
  type;
- fresh ids are distinct and name no DefPath.

`emitter_project_self_test` adds a two-package project whose imported
package copies its own record, on MSIL and the JVM. ILVerify reports the
compiler bundle clean. `typechecker_extern_dedup_self_test` and the rest of
the self-test and CI suites pass unchanged.
