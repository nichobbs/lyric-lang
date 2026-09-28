# CI: shared test-job setup action, compiler bundle staged once and in the background (#7609)

Three changes to `.github/workflows/ci.yml`, following the JVM split
(2026-09-27-ci-split-jvm-self-tests.md):

- **Shared setup action.** `.github/actions/lyric-test-setup` sets up .NET
  (and Java 21 with `java: 'true'`), downloads `build-artifacts` and runs
  `scripts/ci/write-lyric-dotnet-wrapper.sh`. Fifteen jobs that repeated
  those four steps now call it, which takes `ci.yml` from 498.5 KB to about
  488 KB against GitHub's 512 KB workflow-file limit.
  `numbered-backend-self-tests` keeps its own steps, since each carries a
  per-shard `if:`.
- **The compiler bundle is staged once.** The `build` job stages
  `Lyric.Compiler.dll` into both uploaded directories. The "MSIL backend
  self-tests M2a-M2d" step in `compiler-self-tests-dotnet-b` re-ran
  `scripts/stage-selfhosted-compiler.sh` with identical arguments on the
  downloaded artifact, which took most of that step's ~4.5 minutes and made
  `compiler-self-tests-dotnet-b` the longest job. It now uses the bundle
  from `build-artifacts`.
- **`build` stages in the background.** Staging takes ~3.5 minutes, the
  largest step in `build`, and needs only the AOT binary. It now starts
  right after the AOT build as a `background: true` step, overlapping the
  example, BuildInfo and proof steps, and a `wait-all` barrier holds the
  artifact upload until it finishes. Nothing in between reads the
  `selfhosted/` directories.

The stale job name in `lyric-web/tests/jvm_server_smoke.l`'s header (the
Undertow smoke step runs in `compiler-self-tests-jvm-b` since #7589) is
also corrected.
