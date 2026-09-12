# D-progress-886 — MSIL: `Task.Run(Action[, CancellationToken])`'s delegate never invoked the passed closure — a lambda passed directly to a REGULAR (non-`@externTarget`) function's `() -> Unit` parameter built `Func<object>` instead of `System.Action` (#5329, bug 1)

**Status:** shipped

**Context.** `Std.Task.Scope.scopeSpawn`/`awaitAll` never actually ran a
spawned closure on `--target dotnet` — the biggest of #5329's five reported
findings, and one that transitively blocks real concurrency on the public
async surface more broadly (#5608, #1491). A minimal repro with zero
dependency on `Std.Task` reproduced it: `taskRunPlain({ -> println("ran") });
t.Wait()` printed nothing and returned immediately, no exception, `t`'s
status `RanToCompletion`.

**Root cause.** Traced via IL-level inspection (a scratch
`System.Reflection.Metadata` disassembler and a `DynamicMethod`-based
reflection harness reproducing the exact bug in isolation, outside this
compiler, to confirm the runtime-level mechanism before touching any code).

A lambda literal passed *directly* as a call argument to a function whose
declared parameter is `() -> Unit` gets its delegate TYPE chosen by
`Msil.Codegen`'s `ELambda` arm via a `returnsVoid` check
(`lyric-compiler/msil/codegen.l`). That check consulted
`cctx.lambdaExternDelegateRetType` — populated ONLY for a lambda passed to
an `@externTarget` function's delegate-bridging parameter (Epic #1877/#3923's
FFI-boundary slice, #5853) — and, finding no entry for a call to a REGULAR
(non-`@externTarget`) function like `Std.Task.scopeSpawn`/a hand-written
`mySpawn(action: in () -> Unit)`, fell straight through to
`cctx.funcRetTypes[lambdaKey]`, which is DOCUMENTED as always `MObject` for
every lambda (the Uniform Func ABI unconditionally synthesizes each lambda's
own `FunctionDecl` with `ret = Some(Object)`) — landing on `returnsVoid =
false` and building a `Func<object>` delegate.

But `typeExprToMsilCtx`'s `TFunction` rule (`() -> Unit -> System.Action`,
Epic #1877 Phase 3's strongly-typed delegate ABI) already commits EVERY
`() -> Unit`-typed parameter's OWN MethodDef signature to a real
`System.Action` — unconditionally, regardless of `@externTarget`-ness. So
the callee's signature says `System.Action`; the call site pushed
`Func<object>`. Confirmed via a `DynamicMethod` reflection harness that this
exact mismatch — constructing a `Func<object>`, storing it through a
statically-`Action`-typed slot with no `castclass` (raw IL `newobj`/`call`
never verifies a constructed delegate's runtime type against the receiving
parameter's static type), and passing it to
`Task.Run(Action, CancellationToken)` — reproduces the bug in complete
isolation: no exception anywhere, the Task completes `RanToCompletion`
immediately, and the target method's body never runs. `Task.Run` internally
pattern-matches its `action` parameter's ACTUAL runtime type before
invoking it (`m_action is Action action`-shaped dispatch); a `Func<object>`
value fails that match silently since the two delegate types share no
inheritance relationship despite both deriving from `MulticastDelegate`.

A SECOND, independent layer of the same gap: even after fixing the
`returnsVoid` check itself, a call to a STDLIB function (the actual
`Std.Task.scopeSpawn` case, as opposed to a same-source-tree `mySpawn`) still
built `Func<object>`. `registerStdlibFunc`/`registerRestoredFunc` (the
cross-assembly registration paths for stdlib and restored/NuGet/path
dependencies respectively) compute a stdlib function's OWN parameter types
correctly (`paramTypes`, feeding the MemberRef signature — always
`System.Action` for a `() -> Unit` param, matching the in-bundle case) but
never populated `cctx.funcParamFnInner`/`funcParamFnRetType` — the maps the
`returnsVoid` fix reads from — at all; only the IN-BUNDLE, same-compilation-
unit token pre-scan (`addPackageTokens`) populated them.

A THIRD, independent, PRE-EXISTING gap surfaced only once the first two were
fixed (caught by the existing, CI-wired `closure_correctness_self_test.l`
regressing after the fix above — `assertPanicsWith(..., { -> panic(...) })`
started failing with `InvalidCastException: Unable to cast object of type
'System.Action' to type 'System.Func`1[System.Object]'`, its message
captured and reported by `Std.Testing.runAndCapturePanic`'s `catch Bug as b`,
since that catch maps broadly onto `System.Exception`). Root cause: invoking
a function-typed PARAMETER directly as a bare call (`fn()` inside
`Std.Testing.runAndCapturePanic(fn: in () -> Unit)`'s own body) unconditionally
went through `lowerFuncValueInvokeMsil`, which blindly `MCastclass`es the
loaded value to the uniform boxed `FuncN<object,…>` TypeSpec before invoking
— correct for the (overwhelmingly common) erased/generic-HOF case, but wrong
for a REAL closed `System.Action` value. Before this fix, EVERY value ever
stored in such a slot was (incorrectly) `Func<object>` anyway, so the cast
was a no-op — two independent wrongs canceling out. Fixing bugs 1/2 above
made the constructed value correctly match its DECLARED type
(`System.Action`, `registerParamsMsil`'s own `fctx.types` entry, computed by
the same unconditional `typeExprToMsilCtx` rule), which is exactly what
exposed this call site's independent, latent cast bug.

**The fix.**
1. `Msil.Codegen`'s `ELambda` arm: `returnsVoid` now ALSO checks
   `cctx.lambdaRetTypes` (already populated, file-scope-only, for ANY
   non-generic declaring function's `TFunction` parameter — the "ordinary
   (non-FFI) HOF" fallback `funcParamFnRetType` write already had, just
   never consulted here) before falling back to the always-`MObject`
   `funcRetTypes` default.
2. `registerStdlibFunc` and `registerRestoredFunc`: both now also populate
   `funcParamFnInner`/`funcParamFnRetType` (keyed `"<arityKey|fqn>#<paramIdx>"`,
   matching the in-bundle convention) for every `TFunction`-typed parameter,
   mirroring the in-bundle "ordinary HOF" registration exactly. Both
   functions already return early for a generic `fn`, so every function
   reaching the new code is non-generic — no `#5334`-style bare-type-variable
   risk.
3. The bare-call `f()` invoke site (where `f` is a local/param resolved via
   `fctx.slots`): checks the slot's own registered `fctx.types` entry first;
   for any REAL void-returning delegate shape — `MClass("System.Action")`
   (zero-arg) or `MGenericInstByName("System.Action`N", …)` for N ≥ 1 — it
   pushes the (boxed) arguments and emits a direct `callvirt` against
   `cctx.tokActionInvoke` (zero-arg, pre-existing but previously never wired
   to any call site) or the new `buildActionNInvokeTok(cctx, N)` (N ≥ 1,
   mirrors the pre-existing `buildActionNCtorTok`, sharing its TypeSpec
   cache key) instead of the uniform-ABI cast-and-invoke path. Every other
   function-value shape — including every NON-void `TFunction`, which is
   ALWAYS `Func`(N+1)<object,...,object>` regardless of arity and therefore
   identical to the uniform ABI's own erasure — is completely unaffected,
   detected structurally from the slot's own registered type, never a
   source-level annotation guess or an arity special-case.

   **This item was originally shipped zero-arg-only** (`args.count == 0`
   hard-coded) and widened to arbitrary arity only after CI caught two
   further regressions on the pushed commit: `Std.Iter.forEach`'s
   monomorphized `(T) -> Unit` callback (arity 1, `stdlib-builds` job:
   `InvalidCastException: … 'System.Action`1[System.Object]' … 'System.Func`2…'`)
   and `Std.Collections.mapForEach`'s `(K, V) -> Unit` callback (arity 2,
   `map_enhancements_self_test.l` via `compiler-self-tests-dotnet-a`) — both
   monomorphized generic stdlib functions reaching `registerStdlibFunc`
   already non-generic, so item 2 above applied to them too and (correctly)
   started constructing real `Action`N` values the ORIGINAL zero-arg-only
   invoke fix didn't yet handle. The general N-ary fix closes the SAME bug
   class at every arity in one pass rather than patching arity-by-arity as
   CI finds them.

**Scope — what this fixes and what it doesn't.** #5329 listed five findings;
this closes two:
- Bug 1 (biggest): `Task.Run(Action[, CancellationToken])` on `--target
  dotnet` — FIXED, verified above.
- Bug 5: `awaitAll` null-dereferencing on an empty scope, on both targets —
  also FIXED as a side effect (the same delegate-construction path
  underlies the empty-scope case; both `testScopeNormalCompletionRunsEveryChild`
  and `testScopeWithNoChildrenCompletesImmediately` in
  `lyric-stdlib/tests/task_scope_known_failures_tests.l` now pass on BOTH
  targets, confirmed).
- Bug 3 (JVM `ClassCastException` for a cross-package spawned closure) was
  ALREADY fixed by D-progress-848 (unrelated PR, same root-cause family:
  the per-package `Lyric$Lambda` interface unified to one shared name) —
  confirmed by running `testScopeSiblingObservesCancelOnFault` (a THIRD,
  unrelated D119-slice-S3 test — see below) on `--target jvm`: it passes
  cleanly today.
- Bugs 2 and 4 remain open and are untouched by this fix: bug 2
  (`Task.GetAwaiter().OnCompleted(Action)` panicking MSIL closure-class
  resolution when combined with another closure in the same compilation
  unit) is not exercised by `scopeSpawn`'s shipped `Task.Run`-based
  implementation; bug 4 (JVM `VerifyError` on a 4+-argument named-function
  `spawn`) is JVM-specific and untouched by this MSIL fix.
- `testScopeSiblingObservesCancelOnFault` (D119 slice S3,
  sibling-cancel-on-first-fault) was NEVER one of #5329's five numbered
  bugs — it tests a separate, larger, not-yet-shipped feature that needs
  bugs 1 and/or 2 above; it now passes on `--target jvm` but still fails on
  `--target dotnet`, and stays in `task_scope_known_failures_tests.l`
  (renamed in scope, still not CI-wired) rather than merging into
  `task_tests.l`.

**Tests.** `lyric-stdlib/tests/task_scope_known_failures_tests.l`'s
`testScopeNormalCompletionRunsEveryChild` and
`testScopeWithNoChildrenCompletesImmediately` were merged back into
`lyric-stdlib/tests/task_tests.l` (already CI-wired on both targets) per
that file's own stated exit condition; verified passing on `--target
dotnet` AND `--target jvm`. `task_scope_known_failures_tests.l` keeps only
`testScopeSiblingObservesCancelOnFault` (D119 S3), re-verified failing on
dotnet / passing on jvm, header rewritten to scope it to D119 S3 rather
than #5329. `_kernel/task.l`'s module doc (the "D119 slice S3" section
describing all three bugs as blockers) updated to mark bug 3 fixed with a
cross-reference, and its `taskWhenAll` doc comment (which cited #5329 as a
reason the binding "stays `@externTarget`") corrected — the runtime path is
now verified working; the auto-FFI migration itself just hasn't been
attempted yet, a separate follow-up.

No regressions, all re-run on this branch's build (both targets where the
file is dual-wired): `closure_correctness_self_test.l` 8/8 (dotnet + jvm),
`jvm/closure_jvm_self_test.l` 14/14 (jvm), `closure_zero_overhead_self_test.l`
18/18, `jvm_lambda_iface_bundling_self_test.l` 7/7, `async_sm_self_test.l`
71/71, `async_spawn_self_test.l` 26/26, `async_generator_self_test.l` 16/16,
`async_extern_self_test.l` 6/6, `bitwise_self_test.l` 10/10,
`aspect_weave_self_test.l` 13/13, `msil_codegen_diag_self_test.l` 0 fail (its
printed `F00NN` lines are the diagnostic-firing negative cases the test
itself asserts), `msil_project_bridge_self_test.l` 53/53,
`cross_package_generics_self_test.l` 10/10. After the N-arity widening of
item 3 above (prompted by CI's own `stdlib-builds`/`compiler-self-tests-
dotnet-a` failures on the pushed commit): `iter_tests.l` (`Std.Iter.forEach`,
arity 1) and `map_enhancements_self_test.l` (`Std.Collections.mapForEach`,
arity 2, 22/22) both re-verified passing, plus a broader stdlib spot-check
(`core_tests.l`, `collections_tests.l`, `string_tests.l`, `set_tests.l`,
`sort_tests.l`, `testing_tests.l`, `mocking_tests.l`, `json_tests.l`,
`regex_tests.l`, `format_tests.l`) all green.

**Follow-up (not done here, out of scope).** Several downstream test files
and one library README carry `#5329` workaround notes (e.g.
`http_roundtrip_self_test.l`'s child-process listener, `lyric-jsonrpc`'s
README) that could now potentially simplify to genuine in-process
concurrency; left untouched — each needs its own dedicated verification
and is a separate, smaller follow-up per file, not a required part of this
fix. Bugs 2 and 4 above, and D119 slice S3 on `--target dotnet`, remain
open and are tracked by #5329's own text and this entry, not by new issues.

**Related:** #5329, #5608, #1491 (both blocked in part by bug 1, now
unblocked for their `Std.Task`-mediated concurrency path — neither is fully
resolved by this fix alone), D-progress-848 (the JVM lambda-interface
unification that independently fixed bug 3), D119/D120 (structured
concurrency), Epic #1877 (closure ABI / strongly-typed delegates), D122
(docs/50, the `@externTarget` delegate-bridging slice this fix generalizes
one step further).
