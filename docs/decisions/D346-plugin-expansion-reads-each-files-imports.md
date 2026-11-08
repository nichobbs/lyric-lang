# D346 - Plugin expansion resolves a name through the imports of the file that writes it (docs/70 phase 2d, #8690)

**Status:** shipped for `Lyric.PluginExpand` (the checked package and, since the
follow-up below, dependency packages) and `Lyric.ComponentGlue`; the other passes
#8690 lists, and retiring `B0012`, the cross-file `T0148` and the cross-file `T0123`, follow.

## Context

Plugin expansion runs before the alias rewrite. It resolved `X.T` and bare names
through one `Ctx` per package whose imports were `SourceFile.imports`, the union of
the files' imports, with the first alias of a name winning. Two files that bind one
alias to different packages therefore had the second file's names resolved through
the first file's package. That is why `B0012` (one alias, two packages) still stands.

## Decision

`Ctx` carries each file's own imports (`fileImports`, indexed by `Position.fileId`,
each file's header imports plus any import a pass added to the package that no header
holds, as `Lyric.Resolve.buildResolverContext` does for the checker). Every name the
pass resolves for the checked package goes through `resolveNamedAt(segs, ctx, st,
fileId)` with the file id of the span that wrote it (a type expression's, an
annotation argument's, an `impl` interface head's). A synthesised node, a package
of one unnumbered file and a dependency package (whose `PluginPackage` still holds
the union of its files' imports) keep the union.

## Consequences

- `plugin_expand_self_test.l` has a package of two files that bind `Types` to
  different packages; each file's point resolves its own. It fails with the per-file
  lookup disabled.
- Still reading the union, so `B0012` stays: dependency packages in `PluginPackage`,
  `Lyric.ComponentGlue`, the JVM `~ctor-import~`/`~selimport~` rename maps, the
  weaver's A0047 lookup, the MSIL alias lookups, and `AliasRewriter`'s rename
  fallback and synthesised-item environment (#8690).

## Follow-up: dependency packages and `Lyric.ComponentGlue`

- `PluginPackage` carries `fileImports` (`collectPluginPackage` fills it for a
  package collected from one assembled file; a package assembled from several
  collected files keeps the union, as their file ids would collide). `ctxOf` hands
  it to the dependency's `Ctx`, and `classifyNamed` takes the file id of the type
  expression itself, not of the referencing site, so an alias chain that crosses
  into a dependency reads that dependency file's imports. The `allows` names of a
  point carry their annotation span's file id the same way.
- `Lyric.ComponentGlue` gets `perFileImports` (moved there from
  `Lyric.PluginExpand`, which now calls it) and `TypeTable`/`PeerPkg` carry
  `fileImports`; `resolveTy` switches the table to the imports of the type
  expression's file (`tableAtFile`) before resolving a bare or qualified name, so
  a peer package's types resolve in the peer's files too.
- Tests in `plugin_expand_self_test.l`: a dependency whose two files bind `Types`
  to different packages (an alias in each), and a two-file package exporting
  `Types.Pos` and `Types.Tag`. Each fails with its lookup disabled
  (`Acme.One declares no public type Tag`; `W0040 ... the type Tag of package
  Acme.One is not pub`).
