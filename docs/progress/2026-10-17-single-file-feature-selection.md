# A single file's features come from its own manifest; `--features` with no manifest is F0049 (#8339)

D182. `lyric build <file>` took the features of the nearest `lyric.toml`
whether or not it listed the file, while `lyric prove <file>` took none for
a file no manifest listed, so the two compiled and proved different `@cfg`
items of the same file; and `--features` on a file with no manifest was
silently ignored by `build`, `test` and `prove`, and by `run`, which did not
take the flag at all and passed it to the program.

- `Lyric.Discovery.singleFileManifest` / `singleFileSourceBuild` choose a
  single file's features once: `--manifest`, else the nearest manifest above
  the file (listed there or not), resolved for the target by
  `Mf.resolveFeatureSelection`; none with no manifest.
  `emitSingleFileOrProject`, the native single-file build and test, the
  `lyric test` `@cfg` pre-check, `typeCheckForProveFile` and
  `sourceBuildsForFile` (so `lyric prove` and the language server) all use
  it. `sourceBuildsForFileUnder` / `Verifier.proveBuildConfigsForSourceUnder`
  take `lyric prove --manifest <m> <file>`'s explicit manifest.
- `Msil.Bridge.checkSourceTypesForFeatures` / `Emitter.typeCheckSourceForFeatures`
  type-check a lone file under features; `Lyric.LlvmBridge.compileToNativeWithFeatures`
  / `Emitter.emitNativeWithFeatures` compile one natively under them.
- `F0049` (`Lyric.Cli.featuresWithoutManifestError`) from `build`, `run`,
  `test` and `prove` when `--features` names features and no manifest
  applies to the file; nothing is compiled. A broken nearest manifest is
  named with its parse error.
- `lyric run` takes `--features`, `--no-default-features` and
  `--all-features` (single file and project, `--watch` included) and passes
  `--manifest` to a single-file build; `lyric build --aot <file>` passes the
  feature flags to its staging build.

Tests: `scripts/ci/single-file-features-e2e.sh` (from
`compiler-self-tests-batch.sh`), an `lsp_self_test.l` case, and a native
case in `native-target-smoke-test.sh`.
