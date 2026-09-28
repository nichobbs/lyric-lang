# The stdlib rebuilt from Lyric.Stdlib.dll keeps each package's imports (#7617)

The v0.7.1 release rejected the simplest use of `List`:

```
error[T0020] unknown name 'newList' (declared in Std.CollectionsHost; add import Std.CollectionsHost ...)
```

for a file that imports `Std.Collections`. A release install has no
`lyric-stdlib/std` source tree, so `Lyric.Emitter.stdlibSourcesFromCompiledBundle`
(and its JVM twin) rebuilds every stdlib package from `Lyric.Stdlib.dll`'s
contract metadata with `RestoredPackages.synthesiseSource`, which renders
`package` plus declarations and no `import` lines. D141's bare-name rule
(#7535, first released in 0.7.1) reaches `List`/`newList` through
`Std.Collections`' whole import of `Std.CollectionsHost`; with the
reconstructed package importing nothing, they were hidden. The contract
already records the imports (`wholeImports`, `selectedImports`), and #7535
threads them for restored dependencies, but not for this path. CI compiles
against the source tree, so it never took the path; a dev build finds the
source by walking up from the binary, and `LYRIC_STD_PATH` also avoids it.

`RestoredPackages.synthesiseSourceWithImports` renders the contract's whole
imports as `import P` and its selective imports grouped as `import P.{a, b}`,
and both compiled-bundle loaders use it. The standalone surface re-check in
`synthesiseArtifact` keeps the import-free form.

Verified by:

- `restored_packages_self_test.l`: the import rendering (whole, grouped
  selective, no selective line for a package imported whole, re-parses), and
  plain `synthesiseSource` staying import-free.
- `restored_stdlib_async_self_test.l`, now in `scripts/ci/compiler-self-tests-batch.sh`:
  the reconstructed `Std.Collections` imports `Std.CollectionsHost` whole, and
  a program using `List`/`newList` compiles through `Msil.Bridge.compileToMsil`
  against the reconstructed stdlib. Both fail before the fix with the release's
  exact T0010/T0020.
