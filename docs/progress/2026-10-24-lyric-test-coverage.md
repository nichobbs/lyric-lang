# `lyric test --coverage` on .NET and the JVM, through the compiler (#5294)

- `Lyric.Coverage` (`lyric-compiler/lyric/coverage.l`) instruments the code under
  test at the statement level; `Std.Coverage` (`lyric-stdlib/std/coverage.l`,
  Tier 14 of `lyric.full.toml`) counts and dumps.  One text rewrite feeds both
  backends, so dotnet and JVM give identical lines (D246).
- `lyric test --coverage` writes `.lyric-test/coverage.info` (lcov) and
  `coverage.xml` (Cobertura) and prints a per-file summary, for a single test
  file and for a project (`--manifest`, summing all test runs).
  `--min-coverage <percent>` gates on the total.
- The D135 JaCoCo path is removed with its converter, `make jacoco`, smoke
  script and CI steps.  `--target native` is rejected, tracked in #8553 behind
  docs/63's debug-information bands.

Tests: `coverage_self_test.l` (instrumentation, hits, exact lcov and Cobertura)
and `scripts/ci/coverage-e2e.sh` (a project with known covered and uncovered
lines gives the exact lcov on both targets, `--min-coverage` met and missed, the
single-file form, native rejected, an empty run is an error), both in
`compiler-self-tests-batch.sh`.

Docs: `docs/01` §13.2, appendix B and the toolchain table of the book,
`docs/10-stdlib-plan.md`, D246.
