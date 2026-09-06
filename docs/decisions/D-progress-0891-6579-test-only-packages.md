# D-progress-891 — #6579 closed: `test_only = true` packages for `[project.packages]`

**Status:** shipped


**Context.** `[project.packages]` had no way to mark an entry as
test-support-only. A shared test fixture (the motivating case: a TLS
private-key module used by several `lyric-*` test suites, D-progress-806)
either had to be duplicated into every consumer's own source tree (keeping
it out of the shipped bundle, at the cost of drift between copies), or
given a real `[project.packages]` entry (one copy, but now shipped in the
production assembly alongside whatever it pulls in).

**Fix.** `PackageEntry` gained `testOnly: Bool`, set by a new inline-table
parse form for `[project.packages]` values: `{ path = "...", test_only =
true }` alongside the pre-existing bare-string and array forms (both of
which always set `testOnly = false`). `buildProjectFromManifest`
(`cli_build.l`) skips a `testOnly` entry entirely when assembling
`proj.packages` into the production whole-project bundle — it is never
read, never contributes source, and never appears in the release
entry-point (`func main()`) scan. Import resolution for single-file
manifest-local builds (`collectImportedOwnPackages`) and `cli_test.l`'s
`libPkgs` construction both scan `[project.packages]` directly, unfiltered
by `testOnly` — a `test_only` package remains fully importable from
`[project.tests]` entries or a manifest-local single-file build, it just
never ships in `lyric build`'s own bundle.

**Verification.** Two new `manifest_self_test.l` cases cover the inline-
table parse form and its `testOnly = false` default for bare-path entries;
two new `cli_build_self_test.l` cases confirm a `test_only` package's
symbols are absent from a built bundle while still being importable by a
sibling `[project.tests]` file that references it.

**Related:** #6579, D-progress-806 (the TLS-fixture case that motivated
this), `docs/20-project-as-dll.md` §3 ("Test-only packages").
