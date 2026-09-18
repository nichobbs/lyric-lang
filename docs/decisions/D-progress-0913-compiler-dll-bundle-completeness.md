# D-progress-913 — `lyric test`'s compiler-DLL resolution verifies bundle *completeness*, not just existence, before linking (#6628)

**Status:** shipped

**Context.** `lyric test`'s linked-DLL path for a `@test_module` that imports
`Lyric.*` compiler packages (`Emitter.compilerClosureDllPaths`, #2364 Stage 5)
prefers the single staged self-hosted bundle (`<libDir>/selfhosted/Lyric.Compiler.dll`)
over the per-package DLL sets when one exists (D111). "Exists" was the only
check: the function trusted the bundle the moment `File.fileExists(bundle)`
returned true, with no verification that the bundle actually *contains* every
package the test's own import closure needs. A bundle staged before a new
`Lyric.<Pkg>` compiler package was added (or before it was wired into that
test's closure) was silently linked anyway — not a build failure, a
**silent wrong-runtime-result** bug (the missing package's symbols resolve
against whatever the bridge falls back to for an unregistered restored-dep
artifact), exactly the failure mode CLAUDE.md's production-readiness section
calls out as worse than a missing feature. Filed as #6628 while landing #5294
(PR #6627); not attempted there.

**Fix.** `compilerClosureDllPaths` now returns `CompilerClosureResult { dlls,
missingPackages }` instead of a bare `List[String]`. Before trusting the
bundle, it reads the bundle's own embedded contract metadata
(`Lyric.ContractMeta.readAllContractsFromFile`, already used elsewhere for
exactly this "what packages does this DLL actually carry" question) and
diffs the bundle's package set against the test's resolved closure
(`loadCompilerPayloads`). A bundle missing anything is rejected outright (with
a warning naming the gap) rather than linked, and the function falls through
to the existing self-hosted-per-package and F#-emitted-per-package candidate
sources in the same order as before. The final F#-emitted fallback loop had
the identical bug at a smaller scope — it silently skipped any package whose
per-package DLL didn't exist rather than reporting the gap — fixed the same
way: `missingPayloadNames` (the shared helper both call sites use) computes
what's still absent after all three candidate sources are exhausted.
`cli_test.l`'s one real call site now checks `missingPackages.count > 0`
before compiling and fails the test run with a diagnostic naming every
missing package and pointing at `make selfhosted-compiler`/`make lyric`,
matching the "fail loud, not silent" contract `lyric test`'s single-file
manifest-dependency path already has (§13.2 of the language reference).

**Verification.** Two new tests in `emitter_project_self_test.l` build a
*real* one-package bundle via `Emitter.emitCompilerBundle` (the same emit
path `scripts/stage-selfhosted-compiler.sh` uses) covering only
`Lyric.CliShell`'s closure: one asserts that a test source importing a
different package (`Lyric.BuildDefines`) against that bundle reports
`missingPackages` naming the gap and does *not* link the incomplete bundle;
the control asserts a bundle that *does* cover the closure still resolves to
the expected single `"Lyric.Compiler\t<path>"` restored-dep entry with zero
missing packages. `emitter_project_self_test.l` 38/38 (was 36/36 pre-fix,
zero regressions in the existing 36).
