# D-progress-941 — `?` implicitly awaits a direct async-call operand (#6920)

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
async function, and its resolution (#7170, iterated through #7174, #7178,
#7179, #7185).** V0012 rejects a *literal* `await` inside a try/catch/finally
region of an async function (the CLR verifier rejects
`AwaitUnsafeOnCompleted` inside a protected region) but is a purely
syntactic AST walk that runs during mode checking, before `Lyric.Propagate`
ever executes — it has no way to see an `EAwait` this pass synthesizes
afterward. A `?` applied to a genuine async call placed directly inside
such a try/catch/finally region (independent of the fix above — that shape
already failed to compile with T0115, unconditionally, before this entry)
would, after the fix above and before this paragraph's follow-up, generate
the same class of invalid-IL suspension V0012 already guards against for
the explicit spelling, instead of a clean diagnostic. This was flagged as a
REQUIRED review finding on the PR that shipped the fix above (#7170):
`implicitAwaitScrutinee` carries its own defensive check — `PropState`
threads `curFnName` / `curFnAsync` / `inTry` through the rewrite walk
(`stateForFn` re-scopes on every named-function entry, mirroring V0012's
`ELambda` reset for a nested function; `stateInTry` re-scopes for a `try`
body, every `catch`, and any `finally`, mirroring V0012's own
`walkStmtForAwaitInTry` `STry` case exactly), and when a rewrite point that
would otherwise synthesize the implicit `EAwait` cannot be proven safe, it
emits a new `F0045` diagnostic instead — a clean, actionable compile-time
failure matching the pre-#6920 safety property for this shape (mentioning
V0012 by name in the message so the two diagnostics read as one story). An
explicit `(await ...)?` in the same position is untouched — V0012 already
catches that spelling at the correct pipeline stage, and
`isAlreadyAwaitedExpr` short-circuits before the new check runs.

The precise scope of "cannot be proven safe" took four more review rounds,
on the same PR, to land correctly — each closed before merge, not as a
separate follow-up:

- **#7174** — the #7170 guard as first written fired for *any* `?`
  scrutinee inside a try/catch/finally in an async function, not just a
  direct call to a known async function; a call to an ordinary sync
  function, and a bare local variable, both false-positived (`EAwait`'s
  codegen is a no-op when the value isn't Task-shaped, so both are
  provably safe). Narrowed to a same-file bare-name call proven `async`.
- **#7178** — the #7174 narrowing over-corrected the other way: only a
  same-file bare-name call to a *known* async function was flagged, so a
  cross-package/qualified call, a method call (both parse as `ECall(fn =
  EMember(...))`), and a call to a locally-nested `async func` (never
  collected into any same-file top-level name set) all silently fell
  through as "safe" even though all three can genuinely be async. Flipped
  the default: `isRiskyTryCallScrutinee` now flags any call-shaped
  scrutinee unless it is a bare same-file call *proven* non-async
  (`PropState.syncFuncNames`) or a builtin `Ok`/`Err`/`Some`/`None`
  constructor call.
- **#7179** — `rewriteExpr`'s `ELambda` case never reset `inTry` before
  descending into a lambda body, unlike `stateForFn` and V0012's own
  `walkExprForAwaitInTry`. Verified this was not a *live* false positive (a
  `?` written directly in a lambda body classifies as `PropInLambda` and
  gets its own `F0020` before `implicitAwaitScrutinee`/F0045 is ever
  reached), but fixed the latent state-tracking gap anyway
  (`stateForLambda`) to match V0012's invariant exactly.
- **#7185** — `isRiskyTryCallScrutinee` only inspected `ECall`/`EParen`
  scrutinees, so a composite `if`/`match`/value-position-`try` scrutinee
  whose branches are direct async calls fell through as "safe" too —
  `msil/codegen.l`'s own Phase-B pre-scan (`inferCallReturnTypePB`) has
  dedicated `EIf`/`EMatch` cases for exactly this reason. `EIf`/`EMatch`
  scrutinees are now flagged unconditionally; a value-position `try`
  expression doesn't parse to the `ETry` AST case (dead — see
  `hoist_engine.l`'s own note; it desugars to `EBlock([STry(...)])`), so
  `blockEndsInTry` recognizes that actual shape.

An explicit `(await ...)?` in the same position remains untouched throughout
all four rounds. The broader fix (extending V0012 itself, or otherwise
making `Lyric.Propagate` / the mode checker aware of `async`-ness across
package boundaries or through real type information) is still a separate,
larger follow-up, deliberately not attempted here per the "ship the slice
you can finish properly" standard — this fix only turns the silent-bad-IL
risk back into a safe compile-time failure for every scrutinee shape this
pass can prove safe or cannot prove safe; it does not attempt the strictly
larger job of proving individual composite-expression branches safe.

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

The #7170 follow-up added an "F0045: implicit-await ? inside try/catch/
finally in an async func" section covering the diagnostic (source-string
unit tests against `lowerPropagateFile` directly, matching the existing
F0020 error-path tests' style): fires for the implicit-await scrutinee in a
`try` body, in a `catch` handler, and in a `finally` block; does not fire
for an explicit `(await ...)?` in the same position, for an implicit-await
`?` outside any try in an async function (#6920's own case, unaffected),
for a `try`/`catch` inside a non-async function (blocking-shim codegen has
no protected-region hazard), or for a nested `async func`'s own `?` that is
declared lexically inside an outer function's `try` but is not itself
inside any try of its own.

The #7174/#7178/#7179/#7185 rounds each added their own regression cases to
the same section: a non-async bare call and a bare local variable staying
unflagged (#7174); a cross-package/qualified call, a method call, and a
call to a locally-nested `async func` all now correctly flagged, plus a
guard that a proven-non-async call and a builtin constructor call stay
unflagged (#7178); a lambda body nested in a try region still getting its
own `F0020` and never leaking `F0045` (#7179); and an `if`-expression, a
`match`-expression, and a value-position `try`-expression scrutinee all now
correctly flagged (#7185). `propagate_self_test.l` sits at 40 cases total
for this pass, all green on a from-scratch clean `make lyric` build,
alongside a 6-suite/179-test collateral sweep of every adjacent async/
propagation self-test (`async_sm`, `async_spawn`, `async_generator`,
`await_hoist`, `propagate_hoist`, `propagate_hoist_entry_polarity`) run
after every round.

`docs/01-language-reference.md` §4.5 (Error propagation, the `?` operator
section) now documents `F0045` alongside the pre-existing `F0020` mention,
per the review SUGGESTION raised on this same PR.

**Files.** `lyric-compiler/lyric/propagate.l`,
`lyric-compiler/lyric/propagate_self_test.l`,
`docs/01-language-reference.md`.
