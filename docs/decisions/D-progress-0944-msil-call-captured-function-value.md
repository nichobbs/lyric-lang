# D-progress-944 — MSIL: calling a captured function value inside a lambda

**Status:** shipped

## Problem

On `--target dotnet`, a lambda body that *called* a function value it had
captured from its enclosing scope failed to build:

```lyric
func compose(outer: in (Int) -> Int, inner: in (String) -> Int): (String) -> Int {
  return { s: String -> outer(inner(s)) }
}
```

```
error[T0123] 2:25: unresolved call to 'outer' (arity 1) ...
```

The shape is independent of generics and of how the value was bound: a
captured parameter, a captured `val`, a function captured two lambda
levels up, and a `(T) -> Unit` callback all failed the same way. `--target
jvm` compiled and ran all of them. Reading a captured function value
(passing it on, returning it) already worked; only a call through it
failed.

## Root cause

`lowerBuiltinOrStaticCallMsil` treats a bare callee name as a function value
only when it is a slot of the current method (`fctx.slots`: a local or a
parameter). Inside a lifted lambda body, a captured name is not a slot; it
lives in the closure class (`fctx.captureNameToIndex`), or in a by-reference
cell for a hoisted `var` (`fctx.hoistedCellSlot`). Such a call fell through
to static function resolution, found no function of that name, and hit the
T0123 guard.

## Fix

- A bare call whose callee is a capture or a hoisted cell now loads the
  value through the ordinary value-read path (`lowerExprMsil` of the path,
  which already handles both closure-class fields and cells) and invokes it.
- The invoke step after loading is factored into `invokeLoadedFuncValueMsil`
  and shared with the slot path. A `System.Action`/`Action`N` value (the
  shape every `(T1, ..., TN) -> Unit` function type lowers to, D-progress-886)
  gets its direct typed `Invoke`; everything else goes through the uniform
  boxed `Func` ABI.
- The enclosing function's `funcValRetTypes` entries for captured names are
  copied into the lambda's context (`CodegenCtx.lambdaCaptureFuncRetTypes`),
  so the call's result is unboxed to its declared return type exactly as it
  is for a slot call.

## Verification

`closure_correctness_self_test.l` gains five cases: a captured parameter, a
captured function-valued local, a generic function's lambda, a captured
`Unit`-returning callback, and a function captured two lambda levels up.
All pass on `--target dotnet` and `--target jvm`. The neighbouring closure
suites (`closure_zero_overhead`, `record_field_closure`,
`generic_closure_container`, `config_closure`, `enum_closure_pattern_bind`,
`lambda_bool_if_cond`) are unchanged.

Found while implementing the UI library's `mapView`, which composes a child
view's message constructor with the parent's wrapper inside a lambda.
