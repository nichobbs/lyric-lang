# D289 - The language server runs `Lyric.PluginExpand` (#8488)

**Status:** shipped

## Context

D207's desugaring pass generates `<C>Client`, `<P>Remote`, `pluginEncode<T>`, a
plugin's `main` and more. The build runs it after `Lyric.WireExpand`; the server
checked files without it, so those names were unknown in the editor and the
K-diagnostics never appeared (docs/01 §15.11 listed the limit).

## Decision

1. For each build that compiles a document, after `@cfg` erasure and before
   `pipePrepareForCheck`, the server runs `PluginExpand.expandFile` over the
   plugin packages of the document and of every workspace package it imports,
   directly or not (`PluginExpand.collectPluginPackage`, read from disk as the
   imported packages are).
2. Imported workspace packages are expanded too, so a host sees the
   `<p>Remotes` an API package generates. A file with no plugin annotation is
   passed through.
3. K-diagnostics are published at their source spans. Generated items keep
   PluginExpand's declaration-line padding, so an error inside generated code,
   and go-to-definition on a generated name, point at the annotated declaration.
   The workspace definition search expands plugin-bearing files for the same
   reason. After a K error the check still runs for hover and navigation, but is
   not reported, as for any failed rewrite.
