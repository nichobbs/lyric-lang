# D-progress-890 — port: `BMod` codegen claims `MInt` for a `Double` lhs, corrupting the field (#5992/#7035)

**Status:** ported into this PR from the unmerged PR #7041.

**Context.** This PR's own scope is #6835/#6120 (union structural equality).
While rebasing onto `main` after the base branch's `ci.yml` was fixed (a
separate, unrelated CI infra issue, see the PR's own comment thread), CI's
`compiler-self-tests-dotnet-a`/`-b` job failed on `module_val_deps_self_test.l`
test 8 ("Double-lhs BMod/BDiv dependent module vals predict the right field
type", #5992) — a failure entirely unrelated to this PR's own diff.

**Root cause (not this PR's, ported as-is).** `lowerBinopMsil`'s `BMod` arm
had no `MDouble` case. `rem` is type-preserving (a `Double` lhs leaves a real
`float64` on the stack), but the fallback arm claimed the result type was
`MInt` regardless of operand type — matching `BDiv`'s structure exactly,
except `BDiv` already had the `MDouble` case `BMod` was missing. For a
module-level `pub val`, that claimed type becomes the field's declared MSIL
type: the field was declared `Int32` in metadata while the `.cctor` pushed a
`float64` before `stsfld` — invalid IL that different JIT tiers handle
differently, corrupting the stored value on some.

**Fix (ported verbatim).** Cherry-picked commits `ca0a05f` ("fix(msil): BMod
codegen claims MInt for a Double lhs, corrupting the field (#7035)") and
`72cc53d` ("fix: correct comment direction nit in BMod MDouble arm") from the
still-open, unmerged PR #7041, onto this PR's branch — both apply cleanly,
touching only `lyric-compiler/msil/codegen.l` (21 insertions, 5 deletions,
plus a 1-line comment fix). Fixes both `lowerBinopMsil`'s real `BMod` arm and
the `inferUntypedStaticValMsilType` predictor that has to agree with it,
mirroring `BDiv`'s already-correct `MDouble` handling in both places.

**Why ported here instead of waiting for #7041 to merge.** Per this repo's
CI-red convention: a failure confirmed unrelated to the PR's own diff, with
an existing fix (even an unmerged one), is ported directly rather than
waiting on the other PR to land — the port is a no-op once `main` picks up
#7041 itself. This entry exists to disclose the ported change explicitly
(rather than let it ride along undocumented in this PR's diff) and to avoid
duplicating #7041's own decision-log entry once that PR merges on its own.

**Verification.** `module_val_deps_self_test.l` is exercised in this PR's own
compiler-self-tests CI job; the fix is verified by that job turning green on
the next push (no separate local repro run in this PR — the fix itself is
unmodified from #7041, whose own PR description documents a direct 3-line
minimal repro and a full `module_val_deps_self_test.l` 9/9 pass).

No decision-log entry existed for this fix prior to this port (neither of
the two source commits added one) — #7041 will presumably add its own
canonical entry when it merges; this entry is scoped to the port itself, not
a duplicate of that. (This same port was applied identically across all four
`group:compiler-mono-codegen` PRs; each carries its own copy of this entry
per the one-file-per-branch nature of an unmerged decision log.)
