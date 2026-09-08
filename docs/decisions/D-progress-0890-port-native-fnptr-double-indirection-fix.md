# D-progress-890 — Port: native codegen destructor/closure/trampoline/vtable function-pointer bitcasts over-wrapped in an extra `NPtr` (#7030)

**Status:** disclosure — ported from unmerged PR #7048, not an independent fix.

**Context.** This PR's own `native-backend-self-tests` check failed on
`llvm_heap_self_test.l` (22 of 37 cases), all with a `clang` diagnostic
of the shape `'@T.User.dtor' defined with type 'void (i8*)*' but
expected 'void (i8*)**'`. This PR's diff (`Lyric.Mono` monomorphizer
Object-fallback safety fix) does not touch the native/LLVM backend at
all, so the failure is base-branch-wide, not caused here.

Root-caused to issue #7030 and an already-open, not-yet-merged fix PR
(#7048, `fix/native-fnptr-double-indirection`, based on the older
`dca7bc1`): five call sites in `lyric-compiler/lyric/llvm_codegen.l`
(`emitHeapAlloc`, `lowerLambda`, `trampolineFor`, `lowerClosureCall`,
`lowerIfaceDispatch`) wrap `NFnPtr(params, ret)` — which already denotes
the pointer-to-function type in this codebase's IR type model — in an
additional, spurious `NPtr(pointee = ...)` when bitcasting a defined
function symbol to/from that type. `registerImplVtables`'s own
vtable-constant emission builds the identical cast correctly (no `NPtr`
wrapper), serving as the counter-example that confirmed the bug.

**Fix (ported, not authored here).** Drop the outer `NPtr(pointee =
...)` at all five sites so each bitcast's declared type exactly matches
the value's real LLVM type. Byte-identical to #7048's fix commit,
applied directly to this branch rather than waiting on #7048 to merge
(same "port now, no-op on rebase later" approach already used for
D-progress-886/887/891's earlier BMod-port disclosures on these sibling
branches).

**Verification.** #7048's own author reports `llvm_heap_self_test.l`
37/37 (was 15/37), plus no regressions on `llvm_ir_self_test.l` (14/14),
`llvm_codegen_self_test.l` (35/35), `llvm_ffi_self_test.l` (6/6, exercises
the trampoline path), and `llvm_self_test_n3.l` (10/10, exercises the
vtable-dispatch path). This session could not independently rebuild and
re-run those self-tests: the sandbox's `make stage1-fast` requires a
stage-0 release download that fails here (`GitHub access is not enabled
for this session`), and the only locally-installed `lyric` tool (NuGet
`0.6.2`) predates this fix and cannot self-verify it. The five-line diff
is an exact, line-for-line match against #7048's tested fix (same
context lines, same line numbers), so this port is applied on that
basis, to be confirmed by real CI once the self-hosted runner pool
processes this branch.

**Related:** issue #7030, PR #7048 (unmerged as of this writing — once
it merges to `main`, this disclosure entry becomes redundant and should
be removed on the next rebase, per the same pattern already used for
the earlier BMod-port entries). A second, separate native-backend
failure (`presplitcoroutine` rejected by the CI runner's ancient clang
10 toolchain) is tracked as issue #7060 and is a runner/toolchain
provisioning gap, not a codegen bug — out of scope for this port.
