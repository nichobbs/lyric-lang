# D-progress-939 — `?` implicitly awaits a direct async-call operand (#6920)

**Status:** shipped

**Bug.** `--target dotnet`: `asyncCall()?` — the `?` operator applied
directly to a call to an `async func` (no literal `await`) — failed to
compile with `T0115: cannot resolve name '__lyric_prop_v0' to a value here`
whenever the enclosing function was itself `async`. Wrapping the call in an
explicit `await` first (`(await asyncCall())?`) was a working, already-
documented-as-intended workaround.

**Root cause.** `Lyric.Propagate` (`lyric-compiler/lyric/propagate.l`)
desugars `expr?` into `match expr { case Ok(v) -> v; case Err(x) -> {
return Err(x) } }` (and the `Some`/`None` analog for `Option`), using
`expr` verbatim as the match scrutinee. When `expr` is a direct call to an
`async func`, that scrutinee's real MSIL type — per
`msil/codegen.l`'s `cctx.funcRetTypes` (populated for every async func, both
in-bundle via `seedAsyncFuncRetTypePlaceholderMsil` and cross-assembly via
`registerRestoredFunc`) — is the async kickoff's raw `Task<Result[T,E]>`,
**not** the awaited `Result[T,E]`. The ONLY place the compiler ever unwraps
that Task is the dedicated `EAwait` AST node's codegen
(`emitPhaseBAwait`/`emitBlockingAwait`, both reached only from `case
EAwait(inner) -> …` in `lowerExprMsil`); a bare `ECall` never triggers it.
Testing a Task-typed value against `Ok(v)`/`Err(x)` patterns therefore never
resolves a real payload slot for `v` — the match codegen has no case for a
Task-shaped scrutinee — and the missing binding only surfaces much later, at
the first *read* of the synthesized `__lyric_prop_v<n>` name inside the
enclosing async function's synthesized `MoveNext` body, as the confusing
T0115 "cannot resolve name" panic. The explicit-`await` workaround worked
because it puts a real `EAwait` node in the scrutinee position, which the
already-correct Phase B (`synthesizeAsyncSmPhaseBMsil`) / blocking-await
codegen handles as designed.

This is a gap in `Lyric.Propagate`'s desugaring, not in the async
state-machine hoisting logic itself: Phase B's field-promotion and
`MoveNext` synthesis were never wrong about `__lyric_prop_v<n>` — they were
simply never asked to promote it, because the pre-fix AST never contained
the `EAwait` node that would have told them a suspension could happen there.

**Fix.** `buildResultMatch`/`buildOptionMatch` now wrap the scrutinee in an
implicit `EAwait` unless the caller already wrote one (checked through any
number of enclosing parens, so `(await asyncCall())?` is left byte-for-byte
alone — no double await). This makes `expr?` match the language
reference's existing §7.1 rule ("a direct call to an async function awaits
in place with or without the `await` keyword") for the propagation
operator too, and reuses exactly the already-verified codegen path the
explicit-`await` spelling goes through. It is provably safe for every
non-async scrutinee (by far the common case, e.g. `?` on a local
`Result`/`Option` value, or on a call to a plain synchronous function):
`EAwait`'s own codegen is a no-op pass-through whenever the awaited value is
not actually Task-shaped (`isTaskTypeMsil` false), so the wrap costs zero
extra instructions there.

**Scope note — `?` on an implicit async call inside a `try`/`catch` in an
async function.** V0012 rejects a *literal* `await` inside a
try/catch/finally region of an async function (the CLR verifier rejects
`AwaitUnsafeOnCompleted` inside a protected region) but is a purely
syntactic AST walk that runs during mode checking, before `Lyric.Propagate`
ever executes — it has no way to see an `EAwait` this pass synthesizes
afterward. A `?` applied to a genuine async call placed directly inside such
a try/catch/finally region (independent of this fix — that shape already
failed to compile with T0115, unconditionally, before today) would, after
this fix, generate the same class of invalid-IL suspension V0012 already
guards against for the explicit spelling, instead of a clean diagnostic.
This combination is outside #6920's reported repro (no `try`/`catch`
involved) and was not exercised by any existing test; extending V0012 (or
an equivalent propagate.l-local check) to cover it is tracked as a
follow-up rather than bundled into this fix, per the "ship the slice you
can finish properly" standard — a reliable version needs `Lyric.Propagate`
(or the mode checker) to know which functions are declared `async`,
including across package boundaries, which the current pass does not carry.

**JVM.** Unaffected — verified via a JVM equivalent of the repro
(`--target jvm` compiles and runs it correctly, both before and after this
fix, printing the expected value). The JVM backend's `async func` lowering
is a synchronous stub (docs/44's "async/`?` synchronous stubs" finding): a
direct call to an async function already returns its unwrapped payload with
no Task/Future wrapper to unwrap, so `Lyric.Propagate`'s pre-fix scrutinee
was already the right shape there. No JVM code change was needed.

**Testing.** `lyric-compiler/lyric/propagate_self_test.l` gained an "Async
implicit-await propagation (#6920)" section: the exact reported repro shape
(`asyncCall()?` inside another `async func`, Ok and Err paths), the
already-documented explicit-`await` workaround (parity + no-double-await
regression check), a mixed sync/async `?` chain (proving the implicit
`EAwait` wrap is a no-op for the non-async operand), and an `Option`-flavored
(`Some`/`None`) analog. All run via native `lyric test --target dotnet`
against the self-hosted `Msil.Bridge`.

**Files.** `lyric-compiler/lyric/propagate.l`,
`lyric-compiler/lyric/propagate_self_test.l`.
