# `lyric test --suite` and no compile for a test module the filter empties (#8648)

`lyric test` in project mode compiles the whole project once per
`[project.tests]` entry, so a large project spends almost all of a test run
compiling (#8648 measured ~37 s per entry, 70 entries, under 1 s of tests
each). This change lets a run avoid compiles it does not need; compiling the
library once per run is the follow-up tracked in the same issue.

- `--suite <name>` (project mode, repeatable) runs only the named
  `[project.tests]` entries. A name the manifest does not declare is a usage
  error that lists the declared entries; `--suite` with a test file argument,
  or against a manifest without `[project.tests]`, is rejected. `--doctests`
  still adds the doctests. CI can split a project's entries across jobs by
  name instead of rewriting the manifest.
- A test module in which `--filter` selects no test is no longer compiled. It
  prints `N test(s), none match --filter; not compiled` and does not fail; the
  project-mode summary counts such entries as `not run`. Single-file mode does
  the same. `Lyric.TestSynth.Synthesised` gains `selectedCount`, the number of
  runnable tests the filter selects, which the runner checks.

Verified by `test_synth_self_test.l` (selected count with and without a
filter, and with a gated test) and by running `lyric test` against a project
with several `[project.tests]` entries: `--suite` selection, the unknown-name
and single-file errors, and `--filter` skipping the compile of non-matching
entries.
