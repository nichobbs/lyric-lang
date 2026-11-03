# Qualified type paths resolve through `Lyric.Resolve`, docs/70 phase 2c (#8612)

D331.

- `symTableQualifiedType` answers `Owner.Name` in type position from
  `resolvePath` in the file's scope; the checker's owner-matching, re-export
  and type-preference scans in `resolveTypePath` are deleted, as is the
  `packageImports` clause of `qualifiedTypeOwnerAccepts`.
- A package-private type named through its package stays T0097 (#7548).
- `Lyric.AliasRewriter`: the unused `asAliasOf` and its stage-0 workaround
  commentary are removed. `resolve_self_test.l` gains a first-wins test for two
  bare imports sharing a tail (#3250).
- `Lyric.TypeAliasResolve` is not folded; it waits for phase 2d (D331).
