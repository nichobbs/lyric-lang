# `lyric test`: test modules merge into their package; `--doctests` (#678)

Closes the open items of test runner v2 (#678):

- A `@test_module` that declares a `[project.packages]` package is compiled as
  one more file of that package, in project mode (`--manifest` or discovered)
  and in single-file mode (`lyric test tests/account_tests.l` near a
  manifest), on dotnet and the JVM.  Its tests reach the non-`pub` items of
  every file of the package.  A test module of another package name stays a
  separate, `pub`-only package.  Decision: D245.
- `lyric test --doctests` runs the ` ```lyric ` blocks of `///` and `//!`
  comments as tests (`Lyric.TestSynth.extractDoctests` / `buildDoctestModule`),
  titled `doctest <path>:<line>`, merged into the documented package by the
  same rule.  `lyric test --doctests` over a project adds one run per source
  file with doctests after the `[project.tests]` entries, and runs when the
  manifest has no `[project.tests]` at all.
- Already shipped and verified against the code before this change:
  `--manifest` multi-file discovery (`cmdTestManifest`) and
  `--update-snapshots` (D-progress-912, #6906).

Tests: `test_synth_self_test.l` (extraction, module building, annotation
add/remove keeps positions) and `scripts/ci/test-package-merge-e2e.sh`
(manifest and single-file, dotnet and JVM: private function, private `val`, a
second file of the package, a pub-only control, passing and failing doctests),
run from `compiler-self-tests-batch.sh`.

Docs: `docs/01` §3.2 and §13.2, `docs/24` §2/§4/§5, book chapter 15 and
appendix B.
