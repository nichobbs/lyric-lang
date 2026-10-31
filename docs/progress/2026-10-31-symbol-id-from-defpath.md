# A type's identity is its DefPath, docs/70 phase 2b (#8612)

The type part of docs/70 phase 2b (D304).

- **`SymbolId` replaces `TypeId`** in the type checker and the LSP.
  `typeIdEq` is `symbolIdEq`.
- **`DefPath`** (`Lyric.TypeChecker`, `typechecker_types.l`) is a package
  plus a path, rendered with `::` (`defPathKey`). `typeDefPath(pkg, name)`
  is `Pkg::Name`. `externTypeDefPath(host)` is `extern::<host name>`.
- **Interning.** The symbol table interns DefPaths to dense ids
  (`symTableInternDefPath`, `symTableDefPathKeyOf`). `registerItem` and
  `registerExternalImports` take a type's id from its DefPath
  (`symTableTypeSymbolId`), and a declaration with no package takes a fresh
  one (`symTableFreshSymbolId`).
- **Deleted:** the per-check counter (`TypeIdCounter`, `freshTypeId`) and
  `findExternTypeIdByClr`.

Effect: a package registered twice in one check (a restored dependency
also compiled from source) has one id per type. The registrations no
longer give two types that only the scan order kept apart (#1435, #8589).

Not in this step:
- DefPaths for functions and values, which need an overload discriminator;
  these come with phase 2c, their first consumer.
- `LocalId`, which comes with phase 3a.

Tests: `typechecker_self_test` gains cases for one id across two
registrations and its key, extern types identified by host name, and
fresh ids.

Docs: docs/70 §4.2 (the DefPath grammar) and the phase 2b status.
