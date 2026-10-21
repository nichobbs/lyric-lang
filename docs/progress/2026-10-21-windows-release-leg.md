# Windows win-x64 release leg and CLI runtime fixes

The `win-x64` leg of `publish.yml` had been disabled since #3941. The original
blocker (the F# stage-0 mint) is gone, but re-enabling the leg as-is could not
work: `bootstrap.sh` downloads a seed binary for the current platform from the
latest release, and no release has ever shipped a `win-x64` asset.

## Release pipeline

- New reusable workflow `.github/workflows/windows-build.yml`. A Linux `managed`
  job runs `bootstrap.sh --stage 3` and uploads the stage-2 compiler/stdlib DLLs
  (managed IL, RID-independent) plus `lyric-resolver.jar`; a `windows` job
  downloads them, NativeAOT-links `lyric.exe`, stages `lib/` and the resolver
  jar, smoke-tests (`--version` matches the requested version; `lyric run` of
  `examples/fizzbuzz.l` from outside the checkout), and zips the result.
- Entry points: `workflow_call` from `publish.yml` (`build-windows`, attaches
  the zip to the draft release), `workflow_dispatch` (dry run, artifact only),
  and `pull_request` on changes to the workflow or `Lyric.Cli.Aot`.
- Unsigned: the Authenticode step was removed from `publish.yml` (it was dead
  code behind `matrix.authenticode`); re-add it to `windows-build.yml` once the
  Key Vault secrets exist.
- Not yet a release gate. `publish-checksums` now runs with `always()` so a
  Windows failure ships the release without the zip rather than deleting it via
  `cleanup-on-failure`. Promote it to a required need of `finalize-release`
  after a green dry run and one green release.

## CLI runtime

- `lyric test` temp-dir fallback honours `TEMP`/`TMP` as well as `TMPDIR`.
- `canonicalDir` (`lyric restore` local-dependency dedup) normalises `\` to `/`.
- `lyric upgrade --github` fails on Windows with an actionable message instead
  of trying to run `sh install.sh` against a locked `lyric.exe`.
