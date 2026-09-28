# CI guard: real AOT apphost against a path-dependency manifest and a release-layout stdlib rebuild (#7514)

Issue #7514 (filed 2026-09-27) reported `./bin/lyric test --manifest
lyric-mcp/lyric.toml` failing with T0010/T0020 through the AOT entry-point
binary while `dotnet .../lyric.dll` passed the same suite in CI, and
suspected working-directory or base-directory stdlib probing under AOT.

## Reproduction matrix

Built `LYRIC_BOOTSTRAP_VERSION=v0.7.0 make lyric` and ran the reported repro
shape across every axis the issue named: entry point (the AOT apphost
`bootstrap/src/Lyric.Cli.Aot/bin/$CONFIG/net10.0/lyric` vs the same
directory's `lyric.dll` run via `dotnet exec`) x target
(`--target dotnet` / `--target jvm --no-default-features --features jvm`) x
manifest (`lyric-jsonrpc`, `lyric-mcp`, `examples/rbac` — a manifest with
both a local `path =` dependency and a `[nuget]` dependency) x cwd (repo
root, an unrelated `/tmp` directory with an absolute `--manifest` path, and
a copy of the whole binary directory run from `/tmp`). 16+ combinations, 0
`not ok`, no T0010/T0020 anywhere. `#7514 does not reproduce on current
main.`

## Root cause (already fixed on `main`, ancestor of this branch's HEAD)

`git merge-base --is-ancestor 1035b9b7 HEAD` is true. The two entry points
share identical compiled DLLs and path-discovery code — `Program.cs` is a
pure trampoline into `Lyric.Cli.Program.main` — so the only way they could
differ is a bug in stdlib/dependency path discovery
(`lyric-compiler/lyric/emitter.l`'s `findStdlibSources`) reached only in
some environments. Commit `1035b9b7` ("Stdlib rebuilt from Lyric.Stdlib.dll
keeps each package's imports (#7617) (#7619)", 2026-09-28 14:48+10, on top
of the bare-name-scoping commit `1854b735`/#7535, 2026-09-28 09:56+10 —
both already on `main`) fixed exactly this symptom: an **installed/release
layout with no `lyric-stdlib/std` source tree reachable** fell back to
`Lyric.Emitter.stdlibSourcesFromCompiledBundle` (and its JVM twin),
rebuilding every stdlib package from `Lyric.Stdlib.dll`'s embedded contract
metadata via `RestoredPackages.synthesiseSource`, which rendered no
`import` lines. D141's bare-name rule then hid `List`/`newList` (reachable
only via `Std.Collections`' whole import of `Std.CollectionsHost`),
producing exactly T0010/T0020. The fix
(`RestoredPackages.synthesiseSourceWithImports`, used by both
`stdlibSourcesFromCompiledBundle` and its JVM twin) renders the contract's
recorded imports. A dev-tree checkout (this repo, `make lyric`, CI) never
takes that path — `findStdlibSources` walks up from `Environment.
appBaseDirectory()` then `Environment.currentDirectory()` and finds the
real source tree first — which is exactly why no configuration above
reproduced anything.

## CI guard added

No CI job previously ran the true AOT apphost (as opposed to the
`dotnet lyric.dll` wrapper `.github/actions/lyric-test-setup` always
installs, #7025) against a real multi-package manifest with a path
dependency, nor against a genuine "no source tree reachable" release
layout. Both gaps are now closed, entirely inside scripts the `aot-smoke`
job already runs (0 bytes added to `.github/workflows/ci.yml`, which sits
at 495,751 of the 500,000-byte soft ceiling checked by
`scripts/ci/check-workflow-size.sh`):

- `scripts/ci/release-native-aot-smoke.sh`: after its existing
  hello-world native-AOT check, rebuilds the framework-dependent apphost
  in place (`dotnet build bootstrap/src/Lyric.Cli.Aot`, ~1-2s — the same
  thing `make lyric`'s `aot` target and a developer's `./bin/lyric` are),
  asserts the result is a real ELF and not the `dotnet lyric.dll` shell
  wrapper the job's setup step installs, then runs
  `lyric test --manifest lyric-jsonrpc/lyric.toml` and
  `lyric test --manifest lyric-mcp/lyric.toml` (a real `path =`
  dependency) through it — the exact command from the issue.
- `scripts/ci/native-aot-publish-lyric-cli.sh`: after its existing
  hello-world native-CLI check (published outside the repo, but run with
  cwd still at the checkout, so it never actually exercised the
  no-source-tree fallback), copies the published native binary plus only
  the compiled `Lyric.Stdlib*.dll` bundle into an isolated `mktemp -d`
  directory with no `lyric-stdlib/std` anywhere on its walk-up path and no
  `$LYRIC_STD_PATH`, then builds and runs a program that reaches `List`
  only through `Std.Collections`' whole import — the exact #7619 repro
  shape.

## Validation

- `bash -n` on both modified scripts: clean.
- `scripts/ci/release-native-aot-smoke.sh` run locally end-to-end after
  first simulating the CI setup step (overwriting the apphost with the
  `write-lyric-dotnet-wrapper.sh` shell script): the rebuild step restores
  a real ELF (`file` confirms), the wrapper-detection guard does not
  false-positive on it, and both `lyric-jsonrpc` (38/38) and `lyric-mcp`
  (7+36+7 tests) pass through the rebuilt real apphost. Exit 0.
- The isolated release-layout `List` program (same logic as the
  `native-aot-publish-lyric-cli.sh` addition) verified directly first
  using the already-built framework-dependent apphost + copied
  `Lyric.*.dll` closure in a `mktemp -d` directory with `LYRIC_STD_PATH`
  unset: builds and prints `42` — confirming `stdlibSourcesFromCompiledBundle`
  → `synthesiseSourceWithImports` (the fixed call site,
  `lyric-compiler/lyric/emitter.l:588`/`:623`) resolves `List`/`newList`
  correctly under a genuine no-source-tree layout.
- `scripts/ci/native-aot-publish-lyric-cli.sh` (the real
  `dotnet publish -p:PublishAot=true` path, including the new
  release-layout check) run end-to-end locally with clang/ILCompiler
  already cached from the earlier `--release --aot` build.
- `wc -c .github/workflows/ci.yml` and `scripts/ci/check-workflow-size.sh`
  confirm 0 bytes added to `ci.yml`.
