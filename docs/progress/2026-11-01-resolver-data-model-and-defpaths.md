# `Lyric.Resolve`: the data model, DefPaths and the lookup, docs/70 phase 2c step 3 (#8612)

D313.

- **`Lyric.Symbols`** (new, `lyric-compiler/lyric/symbols/`): `SymbolId`,
  `DefPath`, the DefPath constructors and the interner, moved out of
  `Lyric.TypeChecker`. The checker re-exports the package and its symbol table
  holds the shared `DefPathInterner`.
- **`Lyric.Resolve`** (new, `lyric-compiler/lyric/resolve/`):
  - `resolve_model.l`: `Decl`, `DeclTable`, `FileScope`, `Resolution`.
  - `resolve_collect.l`: DefPaths for every declaration kind, with the
    parameter types as written as the overload discriminator.
  - `resolve_scope.l`: a file's import scope.
  - `resolve_lookup.l`: `resolveBare` and `resolvePath`, the §4.3 rule with the
    direct-over-re-export tier (#8709), T0010, T0020, T0097 and T0123.
  - `resolve_driver.l`: `buildResolverContext`, one scope per file.
- Tests: `resolve_self_test.l`.
- Next: the resolver's body walk and the differential mode against the
  checker, then the checker consuming resolutions with its lookups deleted.
