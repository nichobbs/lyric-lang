# The bare-function tier, import hint and ambiguity come from `Lyric.Resolve`, docs/70 phase 2c step 6 (#8612)

D316.

- `Lyric.Resolve`: `winningStep` factored out of `resolveBare`; new
  `winningPackages`, `ambiguousPackages`, `importHint`.
- The checker's `symTableBareFuncTier`, `symTableBareFuncVisible`,
  `symTableHiddenImportHint` and `symTableAmbiguousImportPackages` answer from
  them over the union of the package's files; the tier scan, the exports check,
  the hint pass and `funcExportCache` are deleted.
- Next: the single lookup (`tryFindOneCore` under the import rule) and T0219
  from the resolver, then the import-rule maps and `installImportRule` data go.
