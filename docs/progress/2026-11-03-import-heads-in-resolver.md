# Import heads and renames move into `Lyric.Resolve`, docs/70 phase 2c (#8612)

D330.

- `Lyric.Resolve` exports `importHeads`, `importRenames`, `importsPackage` and
  `renderImport`: the single definition of what an import binds as a
  qualified-reference head or a rename.
- `Lyric.AliasRewriter` builds its alias and rename entries from them; its own
  copies of the import analysis are deleted. The tree rewrite stays as the
  backend-facing projection until phase 2d (D330).
- Tests: `resolve_self_test.l` (two new cases); `alias_rewriter_self_test.l`
  unchanged and green.
