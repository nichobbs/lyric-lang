# D-progress-888 — Ported native codegen fix: function-pointer bitcasts over-wrapped in an extra `NPtr` (from #7048)

**Status:** shipped (ported)

**Context.** PR #6870 (`lyric-aws-secrets` JVM bindings, tracking #5411)
hit `native-backend-self-tests` failing on its CI run: `lyric_rt_test.c`'s
own C-level tests passed cleanly this time (unlike the job's usual
`lyric_rt_test.c:1642` timing flake, which normally dies before the job
reaches the `--target native` Lyric self-test suite), and
`llvm_heap_self_test.l` then failed 22 of its 37 cases, all with the same
`clang` diagnostic:

```
'@T.User.dtor' defined with type 'void (i8*)*' but expected 'void (i8*)**'
  %t10 = bitcast void (i8*)** @T.User.dtor to i8*
```

This is unrelated to #6870's own diff (`lyric-aws-secrets/` and CI wiring
only). An unmerged PR, #7048 ("fix(native): drop spurious extra pointer
level from NFnPtr bitcasts"), already contains the exact fix, with its
own root-cause writeup and verification claims (see that PR's
`docs/decisions/D-progress-0886-native-fnptr-double-indirection.md`,
which this entry does **not** duplicate — this file exists only to
document the ported code change landing via #6870, and defers to #7048's
own entry for the full root-cause narrative once #7048 merges).

**What was ported.** Only the code change to
`lyric-compiler/lyric/llvm_codegen.l` (5 call sites: `trampolineFor`,
`lowerLambda`, `lowerClosureCall`, `emitHeapAlloc`, `lowerIfaceDispatch`
— each dropping an outer `NPtr(pointee = ...)` wrapper around an
`NFnPtr(...)` bitcast operand type, since `NFnPtr` already denotes the
pointer-to-function type in this codebase's convention). Verified
byte-identical against #7048's diff for that one file before landing.
#7048's own docs/decision-log/native-plan updates were **not** ported,
to avoid a duplicate/conflicting `docs/decisions/` entry once #7048
merges on its own — this entry is the substitute documentation for the
port itself, per claude-review's REQUIRED finding on #6870
(issue #7051).

**Verification.** This session's sandbox runs a published NuGet global
`lyric` tool that lacks the bundled self-hosted compiler packages
(`Lyric.Parser`, `Lyric.LlvmCodegen`, etc.), so `llvm_heap_self_test.l`
cannot be built/run in-process here — attempting it fails with
`unknown name 'parse'` / `'codegenNativePackage'` (those symbols only
resolve against a from-source `./bin/lyric` build, unavailable in this
sandbox per the existing D-progress-543 sandbox-exception precedent).
This entry does **not** claim to have independently re-run
`llvm_heap_self_test.l` 37/37 locally — that verification is #7048's
own (documented in its PR body and `D-progress-0886` entry). What *was*
verified here: the ported diff is byte-identical to #7048's diff for
`lyric-compiler/lyric/llvm_codegen.l` (confirmed via direct diff
comparison before commit), and `lyric fmt --write` made no changes to
the ported file. The actual runtime verification for this specific
port is `native-backend-self-tests` passing on PR #6870's own CI run
after this commit — CI is the verification, not a locally-reproduced
test run.

**Related:** #7048 (source PR, unmerged as of this entry), #7051
(claude-review's REQUIRED finding on #6870 asking this port to be
documented), `native/plan/08-work-items.md` N9.10 (tracked in #7048,
not duplicated here).
