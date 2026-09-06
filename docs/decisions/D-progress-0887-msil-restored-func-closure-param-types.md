# D-progress-887 — MSIL codegen: a consumer closure literal passed to a restored function's function-typed parameter now propagates the declared inner/return types, fixing stdlib `Result[T, E]` identity across the restored-package boundary (#3273 item 4)

**Status:** Shipped.

**Background.** #3273 batched four restored-package-boundary correctness gaps
found while redesigning `lyric-health` (#679/D099). Three of the four (enum
miscompile at consumer call sites, W0003 always-true `isinst` on a
payload-free restored union, payload-bearing restored union field
extraction) were re-verified FIXED against current `main` in the most recent
triage pass (D-progress-720, PR #6345). #3273's own 5th item (bare top-level
function references as delegate values) is ALSO independently fixed on
`main` since that triage — D-progress-738 (MSIL) and D-progress-747 (JVM),
both re-verified here with `bare_func_ref_self_test.l` (wired into CI on
both targets). That leaves this entry's fix as the last open sub-item: a
consumer closure that constructs `Ok(...)`/`Err(...)` DIRECTLY (not via a
function call) and is invoked-and-matched inside a RESTORED library still
panicked, specifically when the closure crosses the restored-package
boundary — a narrower, more precisely-scoped repro than #3273's original
"stdlib Result identity is not stable across the boundary" framing (which
also described the SAME-bundle closure shapes D-progress-720 already fixed).

**The bug, reproduced fresh.** A restored library `pub func matchClosure(f:
() -> Result[Int, String]): Int { match f() { case Ok(v) -> v; case Err(_)
-> -1 } }` called from a consumer as `matchClosure({ -> Ok(42) })` threw
`System.InvalidCastException: Unable to cast object of type
'Std.Core.Result_Ok`2[System.Int32,System.Object]' to type
'Std.Core.Result`2[System.Int32,System.String]'` — the closure constructed
`Result_Ok<Int, Object>` (the `E` type parameter, unreachable from `Ok`'s own
`value: T` payload, erased to `object`) instead of `Result_Ok<Int, String>`.

**Root cause.** `#6511` (an earlier fix, still correct for IN-BUNDLE calls)
threads a directly-passed lambda argument's declared inner/return types
(`cctx.lambdaParamTypes`/`cctx.lambdaRetTypes`) from the CALLEE's
function-typed parameter into the lifted lambda body's own `FuncCtx`, so a
bare union-case construction whose OTHER type-parameter slot isn't pinned by
an argument (`E` in a bare `Ok(v)` closure returning `Result[T, E]`) can
still resolve it from `fctx.declaredRetTy` — the lambda's own return type is
otherwise always `Object` under the Uniform Func ABI
(`collectLambdasBfsExpr` synthesizes every lambda's `FunctionDecl` with `ret
= Some(Object)`, regardless of what it's actually returning). That
propagation is populated at the CALL SITE from
`cctx.funcParamFnInner`/`cctx.funcParamFnRetType`, keyed `"<fqn>#<paramIdx>"`
— but those two maps were populated ONLY by `addPackageTokens` (walking an
IN-BUNDLE `FunctionDecl`'s own `decl.params`), never by `registerRestoredFunc`
(the SEPARATE, simpler registration path a RESTORED/cross-assembly function
goes through). So a lambda passed directly to a restored function's
function-typed parameter always found both maps empty at that key, and its
lifted body fell back to `declaredRetTy = Object` — reproducing the erasure
above. `Err(e)`'s own residual asymmetry noted in the original #3273 triage
(Err already dispatching correctly while Ok didn't, for a same-bundle
closure) is a DIFFERENT, already-fixed defect (D-progress-720's scope); this
entry's repro is restored-boundary-specific and breaks BOTH `Ok(...)` and
would equally break a hypothetical bare `Err(...)` literal missing its own
`T` slot inference — not reached in this repro because `matchClosure`'s
`Err` arm binds nothing (`case Err(_)`), so no case-object was even
constructed for it to expose the same gap; the fix does not depend on which
arm is exercised.

**The fix.** `registerRestoredFunc` (`lyric-compiler/msil/codegen.l`) now
mirrors `addPackageTokens`' function-typed-parameter registration: for each
of a restored function's params whose declared type is `TFunction(...)`, it
records `cctx.funcParamFnInner`/`cctx.funcParamFnRetType` under both the
arity-qualified and bare `fqn + "#" + paramIdx` keys — identical to the
in-bundle logic, including the `@externTarget`-vs-plain branch (a restored
FFI-bridging function's delegate parameter still resolves through
`resolveValueTaskGenericMsilType` first). Restored generic functions are
already excluded earlier in `registerRestoredFunc` (return before this
point), matching `addPackageTokens`' own `declGenerics.count == 0` gate, so
no additional guard was needed.

**Scope note (not fixed here, flagged for follow-up).** The identical gap
exists in `registerRestoredRecordMethod`/`registerRestoredIfaceMethod` (a
closure literal passed to a restored RECORD METHOD's or INTERFACE METHOD's
function-typed parameter) — neither populates
`funcParamFnInner`/`funcParamFnRetType` either. #3273's own repro is a bare
top-level function, so fixing `registerRestoredFunc` alone closes this
entry's scope; the record/interface-method variants are a distinct,
unreported shape left as a tracked follow-up rather than folded in
speculatively — filed as #7006.

**A second, unrelated gap found and deliberately NOT fixed here.** While
building this entry's regression test, a THIRD closure shape was tried: a
`val` bound to the lambda literal first, then passed BY NAME
(`val g: () -> Result[Int, String] = { -> Ok(7) }; matchClosure(g)`). It
panics identically — but reproduces with ZERO restored-dependency plumbing
at all (a single in-bundle file, no `import`, no restored dep), confirming
it is a genuinely SEPARATE, pre-existing, non-restored-specific bug: the
direct-argument detection `#1939`/`#6511` extend (and this entry's fix
extends to restored callees) only fires when
`unwrapParenExpr(callArgExpr(...)).kind` is literally `ELambda` at the call
site; a call argument that's an `EPath` reference to a previously-bound
closure — restored callee or not — never reaches it. Out of #3273's
restored-package-boundary scope (this bug predates and is orthogonal to the
restored/in-bundle distinction entirely), so left unfixed and out of this
entry's regression test; filed as #6877, not folded in speculatively.

**JVM parity.** No equivalent gap exists on JVM, and none is needed: the JVM
backend erases generics at the bytecode level (no reified
`Result_Ok<Integer,Object>` vs `Result_Ok<Integer,String>` distinction — both
compile to the same raw `Result$Ok` class, and `instanceof` never inspects
type arguments), so this entire bug class cannot manifest there. Confirmed
by inspection: `lyric-compiler/jvm/` has no `funcParamFnInner`/
`funcParamFnRetType`/`lambdaRetTypes`-equivalent machinery at all — there is
nothing to erase because there is nothing to un-erase.

**Verification.** The exact repro (`matchClosure({ -> Ok(42) })` and
`matchClosure({ -> Err("boom") })`, both direct-literal call arguments) now
prints `42` / `-1` with exit 0 (was `InvalidCastException` at the first
call) via the two-stage `Lyric.Emitter.emitProject` producer/consumer
harness (`LYRIC_LOAD_COMPILER=1 lyric test`). New regression case added to
`cross_package_generics_self_test.l` ("cross-package Result identity:
consumer closure literal passed to a restored function's function-typed
parameter (#3273)") — the first test in that file to construct a STDLIB
generic union case (not a user-defined one) across the restored boundary,
so it also copies `Lyric.Stdlib.dll` beside the consumer output via
`Emitter.copyStdlibDllsBeside`/`Emitter.findCompiledStdlibDir` (every other
test in the file exercises user-defined generics or a mono-specialised
stdlib function call, neither of which touches the DLL at run time). Full
regression sweep after `make lyric`: `cross_package_generics_self_test.l`,
`bare_func_ref_self_test.l` (both targets), `restored_packages_self_test.l`,
`restored_async_self_test.l`, `msil_restored_qualified_val_self_test.l`,
`restored_slice_list_return_self_test.l`.

**Related:** #3273, D-progress-720 (items 1–4 partial, this entry closes the
remainder of item 4), D-progress-738/747 (#5362/#5366, item 5), #6511 (the
mechanism this entry extends to restored functions), #7006 (the
record/interface-method scope gap noted above, tracked not fixed), #6877
(the unrelated val-bound-closure gap found while building this entry's
test), docs/44, docs/45.
