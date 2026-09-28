# CI: cached compiler bundle, reproducibility check and heavy JVM suites in their own jobs (#PR)

Follows 2026-09-28-ci-parallel-jvm-ecosystem-suites.md. After it, the
longest jobs were `stdlib-builds` (8.2 min), `compiler-self-tests-jvm-b`
(7.8 min) and `build` (7.0 min, ~3.5 min of it staging the self-hosted
compiler bundle).

- **Compiler bundle cache.** `build` restores `Lyric.Compiler.dll` from
  `actions/cache` before staging it. The key hashes exactly what the bundle
  is built from: the stage-1 DLLs (whose bytes already reflect the stage-0
  seed release and every compiler/stdlib source), the compiler and stdlib
  `.l` sources, `scripts/stage-selfhosted-compiler.sh` and
  `bootstrap/global.json`. Stage 1 is deterministic for a given seed and
  source tree (checked locally: two `make stage1-fast` builds are
  byte-identical), so a PR that changes none of those (docs, ecosystem
  libraries, CI) skips staging; any other change misses and stages as
  before, so a stale bundle is never served. A miss saves the new bundle.
- **`stdlib-reproducible-emit`.** The byte-identical double-build check was
  the longest step of `stdlib-builds` (~3 min, run last). It is now its own
  job, and its two corpora (the full stdlib bundle and the whole compiler
  closure) run concurrently, since `verify-reproducible-emit.sh` builds each
  into its own temp directory.
- **`compiler-self-tests-jvm-c`.** The heavy suites from
  `compiler-self-tests-jvm-b`'s last batch (the ecosystem suites script,
  lyric-lambda, lyric-aws-secrets, the two lyric-auth steps, the lyric-web
  and lyric-ws Undertow smokes and the UI suites) ran six at a time on one
  4-vCPU runner and waited on CPU. They now run in their own job; each still
  installs Maven and builds the resolver itself under the existing locks.
- **#7612 review items.** `jvm-ecosystem-suites.sh` prints a start line as
  each suite launches, so a hung suite is visible mid-step, and rejects a
  `LYRIC_JVM_SUITE_JOBS` that is not a positive integer.

The runner-pool comment in `ci.yml` and the references to the job that runs
the lyric-web Undertow smoke (`lyric-web/README.md`,
`lyric-web/tests/jvm_server_smoke.l`,
`scripts/ci/lyric-web-undertow-jvm-smoke.sh`) are updated.
