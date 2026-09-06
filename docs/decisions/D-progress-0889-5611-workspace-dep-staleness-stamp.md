# D-progress-889 — #5611: workspace-dep feature/target staleness stamp; `stage1.stamp` keyed on build start, not completion

**Status:** shipped


**Part 1 — `checkDllIsStale` ignored the feature set.** A workspace
dependency's compiled DLL was cached by mtime alone
(`cli/workspace_builder.l::checkDllIsStale`): comparing the DLL's mtime
against the manifest's and every `.l` source file's. Building the SAME
dependency under a different `--features` selection (or `--target`) leaves
every file on disk with the same mtime it had before — nothing was
touched — so the stale check reported "fresh" and silently reused a DLL
compiled with the wrong `@cfg`-gated code erased or kept.

**Fix.** `checkDllIsStale` gained three parameters
(`cliFeatures`/`noDefaultFeatures`/`target`) and now also checks a sidecar
"feature stamp" file (`<dllPath>.featurestamp`) written by
`writeFeatureStamp` right after `buildWorkspaceDep`'s `buildProject` call
succeeds. The stamp records the exact `(target, noDefaultFeatures,
sorted --features list)` tuple that produced the DLL — not the fully
resolved active feature set, since that's a pure function of (manifest
content, this tuple), and manifest-content staleness is already covered by
the pre-existing mtime check. `featureStampContents` sorts the feature list
before serializing so `--features a,b` and `--features b,a` compare equal.
A MISSING stamp (a DLL built before this change shipped, or built by hand)
is treated as stale, not trusted — one extra rebuild the first time a
pre-existing dependency DLL is touched by this code, in keeping with the
repo's "fail loud / rebuild rather than silently reuse" precedent (#5621).

**Part 2 — `stage1.stamp` raced concurrent edits.** `make stage1`'s recipe
ran `./scripts/bootstrap.sh --stage 1` then `touch .bootstrap/stage1.stamp`
— stamping at build COMPLETION. A `.l` source edited WHILE that build was
running has an mtime after the edit but the stamp gets an even-later mtime
at completion, so a subsequent `make lyric`/`make aot` saw the stamp as
newer than the edited file and skipped recompiling it — a false-green
build that never actually contained the edit (the exact D-progress-651/#5605
incident this issue cites: two independent agents had to manually `rm
.bootstrap/stage1.stamp` to recover).

**Fix.** `make stage1` now `touch`es a `.bootstrap/stage1.stamp.start`
marker BEFORE running `bootstrap.sh`, then uses `touch -r
.bootstrap/stage1.stamp.start .bootstrap/stage1.stamp` to copy that
START timestamp onto the real stamp (removing the marker afterward) —
the minimal fix the issue itself suggested ("at minimum comparing against
build start time rather than stamp write time"), rather than a full
content-hash of the `STAGE1_SRCS` glob. Any `.l` edit landing after the
build starts (whether the build takes one second or twenty minutes) now
has an mtime strictly after the stamp's, so `make`'s existing
`.bootstrap/stage1.stamp: $(STAGE1_SRCS)` prerequisite rule correctly
treats the stamp as stale and reruns `stage1` on the next invocation.
`stage1-fast` already skips touching the stamp at all (a separate, already
correct, pre-existing precaution — see its own recipe comment) and needed
no change.

**Verification.** Five new `cli_workspace_builder_self_test.l` cases pin
part 1's precedence table directly against `checkDllIsStale`/
`writeFeatureStamp` (both now `pub`): no stamp → stale; matching stamp with
fresh mtimes → not stale; different `--features` → stale; reordered
`--features` → still matches (order-independent); different
`--no-default-features` → stale; different `--target` → stale. Part 2 was
verified manually with `touch`/`touch -r`/`stat` (POSIX `touch -r` copies
the reference file's mtime exactly) and by a full `make lyric` re-run
confirming the stamp mechanism still functions end-to-end.

**Related:** #5611, D-progress-651 (the original incident), #5605 (the
`JsonEncodedText.Encode` false-green regression that surfaced it), #5621
(the "fail loud, never silently degrade" precedent part 1 follows).
