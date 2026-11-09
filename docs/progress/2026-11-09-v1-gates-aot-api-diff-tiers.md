# v1.0 gates: AOT audit failure, multi-package public-api-diff, kernel-resident stability tiers

- **#8929.** `make lyric` failed at `bootstrap/src/Lyric.Cli.Aot` because the
  SDK-bundled `Microsoft.DotNet.ILCompiler` 10.0.7 carries GHSA-p3jp-9v83-76w9
  (NU1903, an error under `TreatWarningsAsErrors`). The project now references
  `Microsoft.DotNet.ILCompiler` 10.0.14 explicitly; NuGet audit stays on. The
  version is read from `project.assets.json` by `Lyric.Release`, so the release
  workflow needs no matching change.
- **#8927.** `lyric public-api-diff` walks every per-package contract
  (`readAllContractsFromFile`) and pairs packages by name, so
  `Lyric.Stdlib.dll` and multi-package libraries diff. Added and removed
  packages are reported (removed is breaking). Fixing that exposed a second,
  older defect: `Lyric.ContractMeta.diffContracts` shelled out to
  `lyric --internal-contract-meta diff`, a mode removed with the F# CLI, so the
  command returned "no changes" for every pair of assemblies, including a
  removed `@stable` function. `diffContracts` now compares the parsed
  declarations in-process (removed, added and changed declarations;
  strengthened `requires:` and weakened `ensures:` as breaking; `@experimental`
  as non-breaking), with unit tests in `contract_meta_self_test.l` and
  `scripts/ci/public-api-diff-e2e.sh` covering identical, compatible and
  breaking diffs of a multi-package bundle and the real `Lyric.Stdlib.dll`.
  Docs: `docs/22` §5.3, `docs/01` §13.5, book appendix B.
- **#8928.** `Std.Task`, `Std.HttpServer`, `Std.TcpHost` and `Std.Jvm` (and
  their `_kernel_jvm/`, `_kernel_native/` twins) are `@experimental` on every
  `pub` item, as a default awaiting project-lead review.
  `lyric-stdlib/STABILITY.md` lists them in the experimental table.
