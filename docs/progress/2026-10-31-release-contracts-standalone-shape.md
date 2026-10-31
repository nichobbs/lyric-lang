# Release contract policy, `--shape standalone`, defines on packaging shapes (#6263, #6262, D297)

Three changes to the build axes of docs/63.

**Contracts follow the profile (#6263).** A `release` build leaves `ensures:`
and the `requires:` of non-`pub` free functions unchecked; `--release-contracts`
or `@runtime_checked(release_contracts = full)` keeps them. The standard
library, `@proof_required` packages, ranges and invariants are never elided.
The pipeline marks the file and `elaborateItem` elaborates a view of the
function without the elided clauses, then restores the source-level clauses.
`scripts/ci/release-contracts-e2e.sh` builds one program four ways on dotnet,
jvm and native. Methods of `impl`, records and protected types are #8680.

**`--shape standalone` (#6262).** `Lyric.Release` gains `DotnetStandalone` and
`JvmStandalone`. dotnet: patched apphost + installed runtime + hostfxr + the
staged program, with an `includedFrameworks` runtimeconfig. jvm: `jdeps` +
`jlink` image + `lib/` jars + launcher. `F0044` retired. Host platform only
(#8681 for macOS/Windows hosts and cross-RID). `scripts/ci/standalone-shape-e2e.sh`
runs both artifacts with a scrubbed PATH and no `DOTNET_ROOT`/`JAVA_HOME`, in
single-file and project mode, and checks that a rebuild replaces the directory
and a foreign directory is refused.

**Defines on packaging shapes.** `--define` and `[build.define]` now reach the
`aot` and `standalone` staging compile; the shape no longer gates them.

**Not done: #7971.** The bundled-stdlib check returns the lowered package, which
a cache would have to serialise; the AST has no serialised form. Left open with
the plan already on the issue.
