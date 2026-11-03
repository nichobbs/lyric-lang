# D330 - Import heads and renames are `Lyric.Resolve` scope entries; the alias rewrite is their projection (docs/70 phase 2c, #8612)

**Status:** slice 1 shipped. Aliases and renames as scope entries; the alias
targets (`Lyric.TypeAliasResolve`) and the qualified-type path follow as
separate slices.

## Context

Two passes knew what an import binds: `Lyric.Resolve` (for lookup) and
`Lyric.AliasRewriter` (which recomputed `import X as A`, the bare-import tail
and full-path spellings, and `import P.{f as g}` renames from the raw imports,
plus its own copy of `renderImport` and "does this file import P"). Nothing
kept the two in step.

The rewrite itself cannot be deleted yet. The type checker and every backend
(MSIL, JVM, native) and the language server read the rewritten tree: a
flattened `EPath(["Std","Collections","f"])` is how MSIL and JVM find the
declaring package until phase 2d hands backends resolved callees. Removing the
rewrite before 2d would make the checker accept a tree the backends cannot
lower.

## Decision

1. **What an import binds is decided once, in `Lyric.Resolve`:**
   `importHeads` (explicit aliases first, then bare-import tails, then full
   dotted paths; first wins a tail two bare imports share, #3250),
   `importRenames` (D160), `importsPackage` and `renderImport`.
2. **`Lyric.AliasRewriter` is a projection of those entries.** It spells them
   as its internal `head=package` / `^local=package.name` entries and walks the
   tree; it no longer reads an import's shape itself. Its duplicate
   `renderImport` and `fileImportsPackage` are deleted.
3. **The rewrite stays until 2d.** The alias rewriter's tree walk (about 2.1k
   lines: scoping of locals and parameters against rewrites, per-file
   environments, T0219 reporting) is the backend-facing form of the resolver's
   answers. It is deleted by phase 2d, when backends take resolved callees.

## Consequences

- No behaviour change: the entries are the same strings in the same order.
- A new kind of import binding is added in one place.

## Verification

`resolve_self_test` (heads in order, renames, `importsPackage`),
`alias_rewriter_self_test` (40 cases, unchanged), and the full stdlib and
compiler bundle build.
