# D-progress-941 — A closure bound to a `val`/`var` first, then passed by name, now propagates its own declared `() -> T` type into the lifted lambda body (#6877)

**Status:** shipped

**Context.** `lyric-compiler/msil/codegen.l`'s call-site logic that
propagates a callee's function-typed-parameter declared inner/return types
into a lifted lambda body (`cctx.lambdaParamTypes`/`cctx.lambdaRetTypes`,
the #1939/#6511 mechanism) only fired when the call ARGUMENT expression was
literally an `ELambda` node at the call site
(`unwrapParenExpr(callArgExpr(callArgs[i])).kind { case ELambda(_, _) ->
… }` inside the general function-call lowering path). When the argument
was instead an `EPath` reference to a local `val`/`var` bound from a lambda
literal earlier, this detection was skipped entirely, so the lifted lambda
body never learned the callee's declared return type and the Uniform Func
ABI fell back to `declaredRetTy = Object`:

```lyric
func matchClosure(f: () -> Result[Int, String]): Int {
  match f() {
    case Ok(v) -> v
    case Err(_) -> -1
  }
}

func main(): Unit {
  val g: () -> Result[Int, String] = { -> Ok(7) }
  println(matchClosure(g))  // InvalidCastException:
                             // Result_Ok<Int,Object> -> Result<Int,String>
}
```

A bare union-case construction inside the closure body (`Ok(v)`) whose type
parameter isn't pinned by an argument (`E` in `Result[T, E]`) then erased
that slot to `object`, producing a runtime type
(`Result_Ok<Int, Object>`) that doesn't match what the caller's
`match`/cast expects. Passing the closure directly as a literal
(`matchClosure({ -> Ok(7) })`) worked fine — only the val-bound-then-
passed-by-name shape broke. This is entirely in-bundle — no restored
package involved at all — a general gap in tracking "this local's
initializer was a closure literal, here's the expected function type"
through a `val`/`var` binding, independent of whether the eventual call
target is in-bundle or restored (surfaced while investigating #3273 item
4's sibling restored-boundary bug, which the direct-literal call-arg path
already covers).

**Fix.** Added `registerLocalLambdaLiteralFnTypesMsil` in
`lyric-compiler/msil/codegen.l`, called from all three local-binding kinds
(`LBVal`, `LBLet`, `LBVar`) right before their lambda-literal initializer
is lowered. When the initializer (unwrapped of parens) is an `ELambda` and
the binding carries a `() -> T`-shaped type annotation (resolved through a
type alias too, via the existing `resolveFuncTypeExprMsil`), it predicts
the lambda's own upcoming `cctx.lambdaTicker.count` value — the same
"next `__lambda_<idx>` is this local's initializer" prediction the
direct-argument call-site code already makes — and seeds
`cctx.lambdaParamTypes`/`cctx.lambdaRetTypes` from the binding's own
declared parameter/return types via `typeExprToMsilBodyCtx` (the same
generic-aware conversion the binding's own `annoTy` already uses, so a
`val` inside a generic function's body resolves its enclosing generic
params correctly instead of erasing them). This makes the local binding's
own declared type the source of truth for the lifted lambda body,
independent of how the closure is later invoked — by literal, by name,
across zero, one, or many call sites, or not invoked at all in that
function.

**Testing.** Extended the existing CI-wired
`lyric-compiler/lyric/cross_package_generics_self_test.l` (`--target
dotnet`) rather than adding a new file (`.github/workflows/ci.yml` is near
its documented ~500 KB size ceiling, #6781): three new in-bundle tests
(`buildAndRunSingle` helper, no restored package) — the issue's exact
repro (`val`-bound zero-arg closure, both the `Ok` and `Err` arms), a
`(Int) -> Verdict[Int, String]`-typed val-bound closure against a
user-DEFINED generic union (not `Std.Core.Result`, to confirm the fix
isn't scoped to the stdlib type, and exercising `lambdaParamTypes` too,
not just `lambdaRetTypes`), and a `var`-bound (not just `val`-bound)
variant. All 14 tests in the file pass.

**JVM verification.** The issue speculated JVM is unaffected (JVM
generics fully erase `Result`/`Ok`/`Err` to non-generic classes with
`Object`-typed payload fields) but asked for this to be verified, not
assumed. Verified empirically: `lyric-compiler/jvm/cross_package_generics_jvm_self_test.l`
gained an in-process test (`jvmValBoundMatchClosure`) exercising the
identical val-bound-closure-passed-by-name shape directly against
`Std.Core.Result`; it passes on `main` with zero changes to any JVM
backend file, confirming the bug's class genuinely never arises there.
(A separate, pre-existing, unrelated JVM gap was found and deliberately
NOT touched by this fix while investigating: a `func main()`-style
program that constructs a stdlib generic case class — `Result`'s
`Ok`/`Err` — inside ANY closure body, val-bound or a direct literal
alike, hits `NoClassDefFoundError: Std/Core/Result$Ok` at `java -jar`
runtime, reproduced identically with both closure shapes via `lyric build
--target jvm` / `lyric run --target jvm`; it does not reproduce via
`lyric test`'s `@test_module` path, which is why the new JVM test calls
the function directly in-process rather than through the
`Emitter.emitProject`/`java -jar` subprocess helpers the rest of that
file uses. Left as a separate, unfiled gap for now — out of #6877's
scope.)

**Full regression sweep** (`--target dotnet` unless noted):
`cross_package_generics_self_test.l` 14/14 (dotnet) and 8/8 (jvm,
`cross_package_generics_jvm_self_test.l`), `closure_zero_overhead_self_test.l`
18/18, `func_val_local_rettype_self_test.l`, `hof_type_propagation_self_test.l`
6/6, `funcval_ret_materialize_self_test.l`, `generic_closure_container_self_test.l`,
`closure_correctness_self_test.l` 8/8, `record_field_closure_self_test.l`,
`annotated_binding_unbox_self_test.l`, `enum_closure_pattern_bind_self_test.l`,
`config_closure_self_test.l`, `msil_restored_qualified_val_self_test.l` 4/4,
`result_generic_specialization_self_test.l`, `generic_specialization_self_test.l`,
`nested_generic_self_test.l` 8/8, `slice_byte_lambda_arg_self_test.l`,
`lambda_bool_if_cond_self_test.l`, `aspect_weave_self_test.l`,
`async_spawn_self_test.l`, `bitwise_self_test.l`, `block_shadow_self_test.l`,
`typed_ffi_delegate_self_test.l` 36/36, `bare_func_ref_self_test.l`,
`msil_codegen_diag_self_test.l`, `msil_project_bridge_self_test.l` 65/65,
`msil_restored_bridge_self_test.l` — all green, no collateral damage.
Full clean rebuild (`rm -rf .bootstrap/stage1 bootstrap/src/Lyric.Cli.Aot/bin
bootstrap/src/Lyric.Cli.Aot/obj && make lyric`) performed before this sweep.

**Related:** #6877, #3273 item 4 (the sibling restored-boundary bug this
gap was found while investigating; its own direct-literal call-arg path
was already covered), #1939/#6511 (the pre-existing direct-argument
propagation mechanism this fix extends to local bindings).
