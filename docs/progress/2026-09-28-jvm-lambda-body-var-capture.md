# JVM: a `var` declared inside a lambda body is captured by reference by closures nested in it (#7694)

A closure nested inside a lambda that mutated a `var` declared in that
lambda's own body silently lost the write on `--target jvm`:

```lyric
val outer = { ->
  var x = 0
  val inner = { -> x = x + 1 }
  inner()
  x
}
```

returned `0`, not `1`. `lowerLambda` (`lyric-compiler/jvm/codegen/02_exprs.l`)
builds the lambda body's `FuncCtx` via `makeFuncCtx`, whose
`hoistedVarNames` starts empty, and never ran the by-reference capture
pre-pass over the lambda's own body. The `var` therefore got a plain local
slot instead of a heap cell, and `inner` captured a copy of it by value.
This was the same gap #7690 closed for record, impl and protected-type
methods, left open for lambda bodies. It happened wherever the enclosing
lambda was defined (top-level function, record method, impl method,
protected-type entry) and at any nesting depth.

Fix: `lowerLambda` now runs `runClosureCapturePrePassJvm` over the lambda
body right after building `bodyCtx`. `lowerSpawnCallable`, which builds a
fresh `FuncCtx` for a `spawn` operand the same way, runs it too. A `spawn`
operand is an expression, not a block, and that exposed a second gap:
`runClosureCapturePrePassJvm` skipped mutable-var collection for an
`FBExpr` body. Any `var` in a branch block of an expression-bodied
(`= expr`) function was therefore never hoisted either. Both shapes
returned the pre-mutation value on JVM. The helper now collects `var`s
from expression bodies through `collectMutableVarsExpr`.

`--target dotnet` was already correct. MSIL lifts every lambda to a
function lowered through `lowerFuncMsilScoped`, which has always run the
pre-pass.

Covered by the new dual-target `nested_lambda_var_capture_self_test.l`,
wired into `compiler-self-tests-batch.sh` (dotnet) and
`jvm-generics-self-tests-batch.sh` (jvm). It has nine cases: top-level
single and multiple mutations, three lambdas deep, a middle lambda's `var`,
an expression-bodied function, a `spawn` operand, a record method, an impl
method (called through the interface), and a protected-type entry. Before
the fix, the JVM run returned the pre-mutation value in every case. On
dotnet all cases pass before and after; the impl-method case sits in the
same file as the other closures, which is the layout #7693 (fixed in #7712)
used to desync on MSIL.
