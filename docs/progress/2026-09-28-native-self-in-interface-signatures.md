# `Self` in an interface method signature ships on `--target native` (#7585)

Follow-up to D-progress-1013 (#7550), which shipped `Self` in a protected
type's impl method signature for dotnet/JVM and left native as a
pre-existing, unrelated gap: `registerInterfaceTypes` resolved every
interface method's declared param/return types through
`typeExprToNType`, whose fallback arm panicked on a bare `TSelf` at
interface vtable-type registration — a hard internal panic, not a
diagnostic, for BOTH record impls (pre-existing) and protected-type impls
(newly reachable once D-progress-1013 lifted T0136 for `Self` on
protected impls).

## Fix

Specced in D-progress-1016. A bare `Self` (parameter, return, or the
implicit receiver's own type) now erases to a pointer-width `i8*` in the
interface's own vtable slot signature, matching the interface box's own
erased `obj` slot; a `Self`-typed argument dispatched through an
interface receiver unboxes to its raw pointer at the call site, and a
`Self`-typed return reboxes the erased result into a fresh interface
value reusing the receiver's own already-loaded vtable pointer. A
record/protected impl method's own signature is substituted to the
concrete type before it ever reaches codegen (protected members needed a
new substitution call, `registerProtectedMember`/`collectProtectedMethods`
via `substSelfInFn`; record impls already had this).

`Self` NESTED inside a generic type argument (`List[Self]`,
`Option[Self]`) remains unsupported on native — its generics
monomorphize per concrete type argument, and there is no call site to
infer one from at an interface declaration — but now fails with a proper
`N0006` diagnostic (a normal `error[N0006] file:line:col: message` line
to stderr, naming the interface, method, and source span) reported by a
pre-pass `Lyric.LlvmBridge` runs BEFORE calling into codegen at all, so
the build exits non-zero cleanly — no exception, no stack trace, matching
the mode checker's own pre-codegen diagnostic gate (`N0100`).

## Files changed

- `lyric-compiler/lyric/llvm_codegen.l`:
  - `typeExprToNType`'s `TSelf` fallback erases to `NPtr(pointee = NI8)`.
  - New `isBareSelfTypeExpr`/`typeExprMentionsSelf`/`typeExprHasNestedSelf`/
    `isRawI8PtrType` helpers, plus `nestedSelfShapeMessage`/
    `nestedSelfShapeDiagnostic` (shared message text and `Diagnostic`
    constructor for `N0006`) and `pub func nativeSelfShapeDiagnostics
    (units: List[CodegenUnit]): List[Diagnostic]` — the PRIMARY,
    non-panicking pre-pass `Lyric.LlvmBridge` calls before codegen.
    `panicUnsupportedSelfShape` is kept as a defensive-only fallback for a
    caller that invokes codegen directly without running the pre-pass
    (unreachable via the bridge/CLI path).
  - `NIfaceInfo` gained `methodRetIsSelf: List[Bool]`, populated in
    `registerInterfaceNames` (where the fallback nested-`Self` panic also
    lives) and carried through `registerInterfaceTypes`.
  - `lowerIfaceDispatch` reboxes a `Self`-returning call's result via new
    helper `reboxErasedSelfResult`.
  - `coerceTo` gained two new branches: unbox an already-boxed interface
    value's `obj` pointer, or bitcast a not-yet-boxed concrete
    record/protected value, when the expected type is the erased `i8*`
    Self slot.
  - `registerProtectedMember` substitutes `Self` in a protected member's
    params/return to the concrete protected type before registering its
    signature or resolving its native types (mirrors `collectImplMethods`
    for records); `collectProtectedMethods` does the same for the inner
    (locked-body) function via `substSelfInFn`.
  - Updated a stale comment in `lowerUfcsCall` that listed
    "Self-returning interface methods" among deferred vtable-dispatch
    shapes (`Self` methods ARE now dispatched; only default/generic
    methods remain deferred there).
- `lyric-compiler/lyric/llvm_bridge.l`: `linkAndEmitNative` (the
  convergence point both `compileToNativeWithFlags` and
  `compileProjectToNativeWithFlags` funnel through) calls
  `nativeSelfShapeDiagnostics` and `DiagUtil.diagReportAndAbort`s on the
  result BEFORE calling into codegen — the review fix that makes `lyric
  build --target native` print a normal `error[N0006] file:line:col: …`
  line and exit non-zero, with no exception or stack trace.
- `lyric-compiler/lyric/llvm_self_test_self_iface.l` (new, 9 tests):
  end-to-end native self-test — record and protected impls, `Self`
  parameter and return via concrete and interface receivers, chained
  calls, a not-yet-boxed concrete argument at a Self-through-interface
  parameter, two ASan-clean ARC checks, a direct check that
  `nativeSelfShapeDiagnostics` returns exactly one `N0006` diagnostic
  with a real span and message, and a full end-to-end check that
  `compileToNativeWithFlags` returns `false` (not an exception) for the
  same source. Added to `scripts/ci/native-backend-self-tests.sh`.
- `lyric-compiler/lyric/protected_iface_impl_self_type_self_test.l`: its
  `List[Self]` case moved out (see below); header updated to reflect
  native support for bare `Self`. Added to
  `scripts/ci/native-backend-self-tests.sh`'s `--target native` loop.
- `lyric-compiler/lyric/protected_iface_impl_self_type_nested_self_test.l`
  (new): the `List[Self]` case split out of the file above, dotnet/JVM
  only — running the WHOLE original file on native would still fail
  (interface registration covers every interface in the compiled unit,
  regardless of which test invokes it), so splitting it out lets the
  bare-`Self` cases run on native without waiting on the separate
  nested-`Self` feature.
- `scripts/ci/native-backend-self-tests.sh`: added the new self-test file
  to the in-process loop and the split protected-Self file to the
  `--target native` loop.
- Docs: `docs/01-language-reference.md` §7.5 (protected-type interface
  impls), `book/chapters/10-async-and-concurrency.md`,
  `book/chapters/appendix-b-quick-reference.md` (T0136 row, plus a new
  §B.11 "Native codegen / build diagnostics (N-series)" table listing
  `N0001`-`N0006`), `native/plan/03-type-mapping.md`,
  `native/plan/04-arc-design.md`, `native/plan/08-work-items.md`,
  `native/plan/README.md`.

## Tests

`llvm_self_test_self_iface.l`: 9/9 pass (including two ASan-clean ARC
checks and the two `N0006` diagnostic checks). `protected_iface_impl_self_type_self_test.l`: 4/4 pass on
dotnet, JVM, AND native (previously dotnet/JVM only).
`protected_iface_impl_self_type_nested_self_test.l`: 1/1 pass on dotnet
and JVM (native reports `N0006` cleanly, verified manually via `lyric
build --target native` and covered by `llvm_self_test_self_iface.l`'s
last two cases).

Regression: `scripts/ci/native-backend-self-tests.sh` (25 files/loops, 0
`not ok`), `scripts/ci/native-target-smoke-test.sh` (all green),
`scripts/ci/compiler-self-tests-batch.sh` (66 test-file runs, 0
`not ok`).
