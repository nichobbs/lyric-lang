# The checker takes bare-name answers from `Lyric.Resolve`, docs/70 phase 2c step 4 (#8612, #8709)

D314.

- `symTableTryFindOne` answers from the resolver for the checked package's own
  scope (`resolverPick`), mapping the resolved id back to a symbol by DefPath
  (`symbolOfDefId`); the old scan answers when the resolver does not.
- `symTableBareFuncTier` and `symTableAmbiguousImportPackages` follow the
  resolver for a single-file package.
- The resolver context is always built. `LYRIC_RESOLVE_DIFF=1` compares the two
  answers; `R0001` has the item's span and labelled sides.
- `scripts/ci/resolve-diff.sh` and a CI step run the census.
- Tests: a `typechecker_self_test.l` case for #8709.
- Next: delete the lookups that became redundant, then fold `AliasRewriter` and
  `TypeAliasResolve` into the resolver.
