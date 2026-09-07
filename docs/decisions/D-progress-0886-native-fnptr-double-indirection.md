# D-progress-886 — Native codegen: destructor/closure/trampoline/vtable function-pointer bitcasts over-wrapped in an extra `NPtr`

**Status:** shipped

**Context.** `native-backend-self-tests` has, for the entire duration
of a severe CI-runner-starvation incident, been failing on a
pre-existing, documented, unrelated flake in `lyric-rt`'s C unit tests
(`test/lyric_rt_test.c:1642`, a setsid-escapee process-drain-budget
race) before the job ever reached the `--target native` Lyric
self-test suite. One run finally got past that flake far enough to
run `llvm_heap_self_test.l`, and 22 of its 37 cases failed with a real
`clang` diagnostic:

```
'@T.User.dtor' defined with type 'void (i8*)*' but expected 'void (i8*)**'
  %t10 = bitcast void (i8*)** @T.User.dtor to i8*
```

— every record/union/tuple/generic ARC destructor test, every closure
test, and (per `llvm_self_test_n3.l`'s later manual run) every
interface-dispatch call.

**Root cause.** `Lyric.LlvmCodegen`'s `NFnPtr(params, ret)` case
already denotes the pointer-to-function type in this codebase's type
model — confirmed directly by `llvm_ir_self_test.l`:
`nTypeToIrString(NFnPtr(params = ..., ret = NVoid))` renders
`"void (i8*, i32)*"`, trailing star included. Five call sites in
`llvm_codegen.l` nonetheless wrapped it in an additional
`NPtr(pointee = NFnPtr(...))` when bitcasting a defined function
symbol to/from that type:

- `emitHeapAlloc` — storing a record/union's synthesized `.dtor`
  function into the ARC header's `dtor` field (`fromTy` side, casting
  the global function `@T.User.dtor` down to `i8*`).
- `lowerLambda` — storing a closure's body function into its
  environment struct (`fromTy` side, same shape).
- `trampolineFor` — an FFI-callback trampoline body casting the raw
  `i8*` closure-slot value up to a callable function type before
  invoking it (`toTy` side).
- `lowerClosureCall` — casting a closure's stored raw function pointer
  up to a callable type before invoking it (`toTy` side).
- `lowerIfaceDispatch` — casting a vtable slot's raw function pointer
  up to a callable type before invoking it (`toTy` side).

Each produced a spurious extra level of indirection: `bitcast
void (i8*)** @T.User.dtor to i8*` when the global's real type is
`void (i8*)*` (fromTy side), or a locally-bitcast temp typed
`retty (params)**` handed directly to `call` where a plain
`retty (params)*` was required (toTy side; observed as `'%t5' defined
with type 'i32 (i8*, i32)**' but expected 'i32 (i8*, i32)*'` in the
closure-capture test). `registerImplVtables`'s own vtable-constant
emission builds the identical cast as a plain IR string via
`nTypeToIrString(NFnPtr(...))` directly — no `NPtr` wrapper — and was
already correct, serving as the confirming counter-example once the
bug was suspected.

**Fix.** Drop the outer `NPtr(pointee = ...)` at all five sites so
each bitcast's declared type exactly matches the value's real LLVM
type: `fromTy`/`toTy` becomes `NFnPtr(params = ..., ret = ...)`
directly, never `NPtr(pointee = NFnPtr(...))`.

**Verification.** `llvm_heap_self_test.l`: 37/37 (was 15/37 before the
fix — every previously-failing case, spanning plain records, nested
records, unions, generics, closures, `NativeWeak`, and tuples, now
passes). No regressions: `llvm_ir_self_test.l` 14/14,
`llvm_codegen_self_test.l` 35/35, `llvm_ffi_self_test.l` 6/6
(exercises the trampoline path directly — "closure trampoline runs on
a pthread", "trampolines dedup by callback signature" — both green),
`llvm_self_test_n3.l` 10/10 (exercises the vtable-dispatch path
directly, all interface tests green).

**Related:** `native-backend-self-tests`' own `lyric_rt_test.c:1642`
flake (unrelated, pre-existing, documented in the test's own comment)
is what masked this bug from CI for as long as it did — fixing that
flake is tracked separately and out of scope here.
`native/plan/08-work-items.md` N9.10.
