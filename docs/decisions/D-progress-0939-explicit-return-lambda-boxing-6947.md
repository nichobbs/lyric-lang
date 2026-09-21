# D-progress-939 — `return` inside a lifted lambda body never coerced the returned value to the Uniform Func ABI's declared return type (#6947)

**Status:** shipped

**Context.** #6947 reported that a lambda literal whose body contains an
explicit `return <value>` statement crashes at runtime with
`System.NullReferenceException` on `--target dotnet`, independent of how the
lambda is invoked (direct HOF argument, `val` binding used in tail position)
and independent of the separate #6932/#6690 return-type-registration gap that
had been under investigation on a different PR. Verified to reproduce
identically on `main` at `57b130e`, well before any of the #6690/#6897
lambda-related fixes existed — a genuinely pre-existing bug.

**Root cause (MSIL, `return <value>`).** `Msil.Codegen.lowerStmtMsil`'s
`SReturn` arm has two lowering paths: one for an explicit `return` inside a
`protected type` region (stashes into `__retval` and `leave`s to the
epilogue) and one for every other explicit `return` (`ret` directly). The
IMPLICIT return path — a block's trailing expression, or a fall-off tail
expression, handled in `lowerFuncMsil` — always calls
`coerceTrailingToRetMsil` before emitting `ret`, which boxes a value-type
result when the declared/physical return type is `object`, and pushes a
default value when the tail expression erased to `Never`/`MVoid` against a
non-void return. **Neither `SReturn` branch ever called this coercion.** For
an ordinary top-level function this is invisible: the type checker
guarantees the returned expression's static type structurally matches the
function's own declared return type, so the value already on the stack
always matches what `ret` expects.

It is NOT invisible for a lifted `__lambda_N` body. `collectLambdasBfsExpr`
(lambda lifting) always sets the synthesized function's return type to
`object` — the Uniform Func ABI (#1877) that lets any lambda be invoked
through the same boxed `Func<object,...>`/`Action` delegate shape regardless
of its real logical return type. `FuncCtx.declaredRetTy` for a lifted lambda
is (absent an `@externTarget` delegate-bridging exception, #3923) also
`object`. But the lambda body's own expressions still compute their real,
unboxed types — `x + 1` on an `Int` parameter leaves an unboxed `Int32` on
the stack. An implicit tail return correctly boxes it via
`coerceTrailingToRetMsil`; an explicit `return x + 1` did not, leaving a raw
`Int32` where `ret` (or the protected-region `__retval` slot store) expected
an object reference. That mismatch is invalid IL; the non-verifying JIT this
compiler targets accepts it silently and treats the bit pattern as a garbage
object reference, which faults as `NullReferenceException` the first time
the caller dereferences the "returned" value (e.g. unboxing it back at the
`g(5)` call site). Confirmed directly with `ilverify`
(`[StackUnexpected]: found Int32, expected ref 'object'`) before the fix and
a clean verify after.

The issue's own hypothesis (uninitialized `FuncCtx` state, e.g. a missing
`epilogueLabel`) was investigated and ruled out: `epilogueLabel` is always
reserved up-front by `lowerFuncMsil` for every function including lifted
lambdas (see the `panic` guard in `SReturn`'s protected-region arm, which
never fired). The actual defect is a missing call to an existing,
already-shared coercion helper — a lowering-completeness gap, not a
state-initialization gap.

**A second, related MSIL gap (bare `return`, no value).** Fixing the
`Some(e)` arms surfaced a second instance of the same defect class: a BARE
`return` (no value) inside a `Unit`-returning lambda body also hit invalid
IL — `ilverify`'s `DelegateCtor`/runtime `InvalidProgramException` — because
the physical `object`-declared return type still needs *something* (`null`)
on the stack (or in the protected-region `__retval` slot) before `ret`/
`leave`, not an empty stack. Fixed identically: both `None` arms now call
`coerceTrailingToRetMsil(cctx, fctx, insns, MVoid, fctx.declaredRetTy)`
(guarded by `fctx.declaredRetTy != MVoid`, so genuinely `Unit`-returning
ordinary functions — the only other place a bare `return` type-checks — are
completely unaffected) before consuming the (absent) value.

**JVM parity (verified, not assumed).** `Jvm.Codegen`'s `SReturn` lowering
(`lyric-compiler/jvm/codegen/05_stmts.l`) already routes every explicit
`return <value>` through `coerceValueTo(ctx, insns, ty, t)` before
`emitReturn` — that half of the defect class was MSIL-only, confirmed by a
clean `--target jvm` run of the full regression suite before any JVM code
change. But the JVM analogue of the bare-`return` gap above WAS present:
the `None` arm unconditionally emitted `LReturn` (the JVM void-return
opcode) regardless of the enclosing method's real descriptor return type,
so a bare `return` inside a lifted lambda's `invoke` (declared
`Ljava/lang/Object;`, the JVM side of the same Uniform Func ABI) failed
class-load verification ("Method expects a return value"). Caught by
running the regression suite with `--target jvm` explicitly (as this task
required) — 35/36 passed pre-fix, with exactly the bare-return case
failing. Fixed by reusing the existing `pushDefaultValueJvm`/`emitReturn`
pair (already used by `emitNeverTailReturn` for the analogous
Never-erased-to-void tail-expression case) in the `None` arm instead of the
hardcoded `LReturn`; a no-op for genuinely `Unit`-returning functions
(`pushDefaultValueJvm`'s `JVoid` arm is itself a no-op).

**Fix (summary).**
- MSIL (`lyric-compiler/msil/codegen.l`, `lowerStmtMsil`'s `SReturn` arm):
  call `coerceTrailingToRetMsil(cctx, fctx, insns, retExprTy, fctx.declaredRetTy)`
  in both `Some(e)` branches (plain `ret` path and protected-region
  stash-and-`leave` path) before the value is consumed, mirroring the call
  `lowerFuncMsil`'s implicit-return path already makes; the same call with
  `MVoid` as the source type in both `None` branches, guarded by
  `fctx.declaredRetTy != MVoid`.
- JVM (`lyric-compiler/jvm/codegen/05_stmts.l`, the same `SReturn` arm's
  `None` case): replace the unconditional `insns.add(LReturn)` with
  `pushDefaultValueJvm(insns, ctx.retTy); emitReturn(insns, ctx.retTy)`.

Both are no-ops for every ordinary function (the type checker already
guarantees the returned expression's static type structurally matches the
declared return type there) and fix every lifted-lambda `return` site
uniformly — nested inside `if`/`match`/loops, not just a lambda body's sole
top-level statement — since the fix lives in the single shared `SReturn`
lowering site rather than a lambda-specific special case.

**Verification.** Reproduced the pre-fix `NullReferenceException` with the
issue's exact repro (`apply1({ x: Int -> return x + 1 })`) via `./bin/lyric
run` and `ilverify`; confirmed clean after the fix. Added six regression
cases to `lyric-compiler/lyric/func_val_local_rettype_self_test.l` (the
established home for lambda-return-type-inference regressions, which
already carried a long comment explaining why #6947 was filed separately
and deferred): the exact direct-HOF-argument repro, a `val`-bound lambda
invoked in tail position, a `val`-bound lambda with an explicit outer
`return` too, a reference-typed (`String`, no-box) return, a `Double`
(different value-type box shape) return, and a bare `return` (no value)
inside a `Unit`-returning lambda (the void arms must stay unaffected).
`lyric test` run on both `--target dotnet` and `--target jvm` against a
from-scratch clean `make lyric` build: 36/36 pass on both targets. A tenth
candidate case (`return` nested inside `if`/`else` inside the lambda body)
was dropped from this suite — it independently type-checks fine standalone
but fails inside a `test { }` block (every test body is synthesized as a
`Unit`-returning function by `Lyric.TestSynth`) with a genuinely separate,
pre-existing type-checker bug (a nested lambda-body `return`'s type is
checked against the ENCLOSING function's declared return type instead of
the lambda's own), filed as #7152 and explicitly out of scope here.

**Out-of-scope findings filed separately (not fixed here).**
- #7152 — type checker: a `return` nested inside `if`/`else` control flow
  within a lambda body is checked against the enclosing function's declared
  return type instead of the lambda's own; a front-end bug (blocks
  compilation) unrelated to this entry's MSIL/JVM codegen fix.
- #7166 — MSIL: `ilverify` flags `DelegateCtor: Unrecognized arguments` at
  every call site constructing a `() -> Unit`-typed lambda argument's
  `System.Action` delegate, independent of the lambda body's contents
  (reproduces with a plain fall-off body, no `return` at all) — the program
  still runs correctly under the plain JIT, but the emitted IL isn't
  provably valid for this shape. Confirmed pre-existing and outside this
  entry's diff (`lowerStmtMsil`'s `SReturn` arm only) by isolating the
  repro to a lambda body with no `return` statement whatsoever.

**Related:** #6690/#6897 (the return-type-registration fix that surfaced
this bug during investigation but did not cause it), #1877 (Uniform Func
ABI — the source of the lambda body's `object`-vs-unboxed-primitive
mismatch, present on both MSIL and JVM), #3923 (the `@externTarget`
delegate-bridging exception to the Uniform Func ABI), #7152, #7166 (new
out-of-scope findings, filed separately), #6947 (this issue).
