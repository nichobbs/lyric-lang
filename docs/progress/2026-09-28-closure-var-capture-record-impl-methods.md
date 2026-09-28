# Closures capturing a `var` inside record, impl and protected methods (#7690)

A closure that captures a `var` declared inside a record method, an impl
method or a protected-type `entry` was mishandled on both backends:

- `--target dotnet` failed to build: `error[T0120]: ... captured mutable
  (`var`) local 'x' was not hoisted to a heap cell`.
- `--target jvm` built but miscompiled: the closure wrote the method's own
  local slot instead of a shared heap cell, so the method never saw the
  closure's write (and the closure never saw the method's).

## Root cause

The by-reference closure-capture pre-pass (#1479 v2:
`collectInLambdaNamesBlock`/`collectInLambdaNamesExpr` into
`FuncCtx.hoistedVarNames`) ran only for top-level functions and lifted
lambdas (`lowerFuncMsilScoped` on MSIL, `lowerFuncScoped` on the JVM). The
method lowerings build their own function contexts and never ran it:

- MSIL: `lowerRecordMethodMsil`, `lowerImplMethodMsil`, and the protected
  `entry` arm of `lowerProtectedMsil` (a protected `func` member routes
  through `lowerImplMethodMsil`).
- JVM: `lowerRecordMethod`, `lowerImplMethod` and `lowerProtectedMethod`
  (all via `makeFuncCtxInstance`).

## Fix

One shared helper per backend, called from every method lowering that can
contain a closure:

- `runClosureCapturePrePassMsil(fctx, body)` (`lyric-compiler/msil/codegen.l`),
  called from `lowerFuncMsilScoped`, `lowerImplMethodMsil`,
  `lowerRecordMethodMsil` and the protected `entry` arm (on the desugared
  body that is actually lowered).
- `runClosureCapturePrePassJvm(ctx, body)`
  (`lyric-compiler/jvm/codegen/06_items.l`), replacing
  `computeHoistedVarNamesJvm`, called from `lowerFuncScoped`,
  `lowerRecordMethod`, `lowerImplMethod` and `lowerProtectedMethod`.

The other function-context builders (async state machines, wire
bootstrap/accessors, `__cctor_init`, const folding) lower synthesized
bodies with no user closures. Derive- and aspect-woven bodies are ordinary
functions by codegen time and go through the fixed paths.

## Tests

- `method_closure_var_capture_self_test.l` (5 cases, dotnet and JVM):
  record-method closures assigning an uninitialised and an initialised
  captured `var`, compound mutation across repeated calls, a protected
  `entry` closure with cumulative state, and a protected `func` member.
- `impl_method_closure_var_capture_self_test.l` (2 cases, dotnet and JVM):
  impl-method closures. Kept in its own file because an impl-method closure
  and a record-method closure in one file hit a separate MSIL lambda
  numbering bug, #7693.

Both run in `compiler-self-tests-batch.sh` and
`jvm-generics-self-tests-batch.sh`. The generic-record-method variant
(`var x: T` captured) waits on #7695, where `T` in a body annotation
resolves as a class. A possible nested-lambda variant on the JVM is #7694.
