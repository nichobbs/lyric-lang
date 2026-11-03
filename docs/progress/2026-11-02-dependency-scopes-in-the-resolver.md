# A dependency's signatures resolve in its own import scope, docs/70 phase 2c step 8 (#8612)

D322.

- `ImportedPackage.importDecls` / `DepPackage.imports`: a dependency's imports
  as declarations; `ResolverContext.depScopes`: one scope per dependency.
- The checker resolves a dependency's bare names and alias-qualified paths in
  that scope; `tryFindOneCore` and its reachability walk are deleted.
- Census first (docs/70 §12.2): bundle builds, every `lyric.toml`, every stdlib
  test, strict versus old lookup. Nothing needed migrating.
- Tests: two `typechecker_self_test.l` cases.
- Next: #8722 (alias-only bare union case), then folding `AliasRewriter` and
  `TypeAliasResolve` into the resolver.
