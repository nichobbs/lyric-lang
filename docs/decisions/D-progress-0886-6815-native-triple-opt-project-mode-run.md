# D-progress-886 — #6815 items 2/3(a): `--triple`/`--opt` project-mode threading + `lyric run --manifest --target native`

**Status:** shipped


**Context.** #6809 shipped `--target native` support for a project's own
`[project.packages]` (D-progress-854), explicitly scoping out three
follow-ups tracked as #6815: (1) cross-project `[dependencies]` crashing
rather than degrading cleanly, (2) `--triple`/`--opt` CLI flags having no
effect on a manifest native build, and (3) `lyric run`/`lyric test`'s
manifest modes still hard-refusing native outright.

Verifying #6815 against `main` found item 1(a) (the crash → clean-skip
half of item 1) already fixed, landed alongside #6809 itself
(`workspace_builder.l`'s `buildWorkspaceDeps` skips `{ workspace = true }`
dependencies unconditionally for `Native`, mirroring the pre-existing
`Jvm` skip) — verified by re-reading `workspace_builder.l:101-109` and its
`#6820`/`#6815 item 1` comments, no code change needed there. Item 1(b)
(compiling a dependency's source into the native bundle) remains a
separate, larger design task and is left open.

**This entry covers items 2 and 3(a).**

**Item 2.** `buildProjectFromManifest` (`cli/cli_build.l`) gained two
trailing parameters, `nativeTriple`/`nativeOpt`, threaded from `cmdBuild`'s
already-parsed `--triple`/`--opt` flags (`tripleArg`/`optArg`). The
native-project branch's `effTriple`/`effOpt` resolution now starts from
the CLI value and only falls back to the manifest's `[native]` table when
it is empty — the exact precedence `buildOneNativeWithFeatures` already
used for single-file native builds. Widening `buildProject` itself (the
~20-call-site public entry point used throughout the CLI and self-test
suite) was avoided: a new `buildProjectWithNativeFlags` wrapper carries
the two extra parameters, used only by `cmdBuild`'s manifest branch, so
every other `buildProject` caller (self-tests included) is untouched.

**Item 3(a).** `runProjectOnce` (`cli/cli_run.l`) unconditionally refused
`--target native` with "does not yet support manifest (multi-package)
projects" — even though the `buildProject` call three lines above it had
already succeeded and produced a real, directly-runnable native
executable at `projectBinOutputPath`'s extensionless path. The `Native`
match arm now runs that binary via `Std.Process.run`, forwarding
`userArgs` and returning its real exit code, mirroring `runOnce`'s
existing single-file `Native` case verbatim. `runProjectOnce` is now
`pub`, following the `buildProject`/#5819 precedent, so
`cli_run_native_project_self_test.l` can drive it directly.

**Item 3(b) — deliberately deferred.** `lyric test --manifest ...
--target native` (multi-package test suites) is unchanged.
`cmdTestManifest`'s dotnet/jvm implementation is restored-DLL-centric
(workspace/path dependency resolution, per-package DLL colocation) with
no native analog — native has no restored-binary concept at all, so a
native test-manifest path needs its own design (compiling
`[project.tests]` entries together with `[project.packages]` through
`emitNativeProject`, one binary per test target, and TAP-output handling
under native's no-exception-unwinding constraint per D-N-003/D-N-018).
That is a distinctly larger slice than items 2/3(a) above and is left
open against #6815 rather than folded into this PR at reduced quality.

**Verification.** `cli_run_native_project_self_test.l` (new,
`lyric-compiler/lyric/`, wired into
`scripts/ci/native-backend-self-tests.sh`) exercises both items at the
exact CLI entry points a real `lyric build`/`lyric run` invocation drives:
an empty `--triple`/`--opt` still builds via the host default; a bogus
`--triple` CLI override (with no manifest `[native]` table to mask a
silently-ignored value) now reaches `clang` and fails the build, proving
the plumbing rather than merely that *some* build occurred; a
single-package native project run through `runProjectOnce` returns the
binary's real exit code instead of the old hard-refusal; and forwarded
`userArgs` reach the binary's `Environment.args()` (which includes
`argv[0]`, per `lyric_rt.h`'s `lyric_args_get` convention, so 2 forwarded
args plus argv[0] is 3).

**Addendum (post-review, same PR #6899).** Two `claude-review` SUGGESTION
findings on this PR's own diff exposed real gaps in this entry's scope,
fixed in the same PR rather than filed as follow-ups:

1. `WatchAction.BuildProj` carried no `nativeTriple`/`nativeOpt` fields at
   all, and `runWatchAction`'s arm called plain `buildProject` (always
   empty triple/opt) instead of `buildProjectWithNativeFlags` — so item 2
   was fixed for the non-watch dispatch only; `--watch --manifest ...
   --target native --triple ...`/`--opt ...` silently dropped both flags on
   every rebuild. Fixed by adding the two fields to `BuildProj` and routing
   `runWatchAction`'s arm through `buildProjectWithNativeFlags`. New
   self-test: `runWatchAction` driven directly with a bogus triple under
   `--watch`, confirming it now reaches `clang` and fails exactly like the
   non-watch case (both `WatchAction` and `runWatchAction` made `pub` for
   this, following the `runProjectOnce`/#5819 precedent already used
   elsewhere in this same PR).
2. The project-mode branch (`positional.count == 0` in `cmdBuild`) passed
   the raw `optArg` straight through to `buildProjectFromManifest`/
   `buildProjectWithNativeFlags` without ever calling
   `resolveNativeOptDefault` (D-progress-879's fix, landed in the SAME PR) —
   so a project-mode `--target native` build under the default `--debug`
   profile still fell through to `linkAndEmitNative`'s old hardcoded `-O2`,
   inconsistent with the single-file path this same PR fixes for #6263.
   Fixed by computing `effOptArgProj = resolveNativeOptDefault(optArg,
   Some(mfPath), target, axes.profile)` once, right after `axes` is
   resolved, and threading it (instead of raw `optArg`) into all three
   downstream call sites (`BuildProj` construction,
   `buildProjectFromManifest`, `buildProjectWithNativeFlags`). Not
   independently self-tested beyond `resolveNativeOptDefault`'s own
   precedence-table tests (D-progress-879) plus code inspection — `cmdBuild`
   itself is not `pub` (unlike `runWatchAction`/`runProjectOnce`/
   `buildProject`, none of the `cmdXxx` dispatchers in this codebase are,
   `cmdVersion`/`cmdUpgrade` aside), and observing a successful build's
   resolved `-O` level from outside would need new instrumentation broader
   than this fix warrants.

**Related:** #6815, #6809, D-progress-854, D-progress-852,
`docs/20-project-as-dll.md` §"Native scope note",
`docs/10-bootstrap-progress.md`'s #6815 items 1(a)/2/3(a) entry,
`docs/01-language-reference.md` §13.1/13.4 (`lyric build`/`lyric run`
native project entries).
