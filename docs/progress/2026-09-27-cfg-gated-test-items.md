# `@cfg` on a `test` item no longer breaks the synthesized runner (#7481)

`Lyric.TestSynth` rewrites each `test` into `func __lyric_test_<i>` and
builds a `main` that calls every one of them. It runs before
`Lyric.Cfg.applyCfgErasure`. Since #5609 the rewrite kept a test's
`@cfg(...)` on its synthesized function, so erasure dropped the function
when the feature or target was inactive, but `main` still called it. The
whole file then failed to compile with `T0020 unknown name
'__lyric_test_N'`. The TAP plan also counted the test. `property` items had
the same problem, both with a real `--properties` driver and with the v1
`# skip` line.

The fix: synthesis now decides each `test`/`property` item's gating with
the same predicate erasure uses. The new
`Lyric.Cfg.isCfgGatedOut(active, declared, annotations)` is item-level;
`isFileCfgGatedOut` now delegates to it. Synthesis runs it against the
feature set the compile will erase with, which is already passed to
`synthesizeFor` for the file-level check (#6868), plus the `target.<name>`
pseudo-feature (#7189). An item that will be erased gets no slot in `main`:
no TAP line, no `# skip` line, and it is not counted in `1..N`. The
annotated function is still emitted, so erasure removes it and reports
`F0012`/`F0013` for it like any other item. A gated test's body can
therefore use symbols that exist only under its feature.

`lyric test <file>` now resolves the compiler-DLL closure
(`Emitter.compilerClosureDllPaths`) from the original source, before
synthesis rather than after it. The closure depends only on the file's
`Lyric.*` imports, and synthesis adds only `Std.*` imports, so the result
is the same. Resolving it first means synthesis knows when the compile will
take the `emitTestLinked` path, which always erases with an empty feature
set, and it gates against that set too. This closes the gap documented from
the PR #7182 review, which item-level gating would otherwise have widened.

Verified by:
- new `test_synth_self_test.l` cases: an inactive item is left out of
  `main` and the plan while its annotation is kept, the item runs when its
  feature is active, one target-gated test runs per target, a gated test is
  not reported as a filter skip, and gated properties are handled with and
  without `--properties`. The existing `#5609` annotation-preservation case
  was never registered as a `test`; it is now registered and its assertion
  corrected.
- a `cfg_self_test.l` case showing `isCfgGatedOut` agrees with
  `applyCfgErasure` item by item.
- `cfg_single_file_self_test.l`, which CI runs on both targets: two
  target-gated `test` items (one runs per target) and one test gated by a
  never-active feature whose body would not type-check.
- the new `scripts/ci/cfg-gated-test-items-e2e.sh`, run from
  `compiler-self-tests-batch.sh`. It runs the real CLI over a throwaway
  `[features]` project with and without `--features extra`, and over a
  manifest-less single file with and without `--properties`, on
  `--target dotnet` and `--target jvm`. It checks the exact `1..N` plan and
  which tests ran.
