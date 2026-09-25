# D-progress-964 — Widened arguments and typed results of a function-value call (#7250)

**Status:** shipped

## Problem

A call through a function value (a local, a parameter, a record's function
field) accepted an `Int` argument for a `Long` parameter, as a direct call
does, but the call is erased: the argument reached the function boxed as an
`Int32` (`Integer` on the JVM) and the function's unboxing to `long` threw
`InvalidCastException` / `ClassCastException`. `f(2, 40)` failed on both
targets for `f: (Int, Long) -> Long`.

On the JVM the same erasure affected the result: a call through a local or a
parameter annotated with a function type left its `invoke` result as
`Object`, and a consumer that anchored on the other operand unboxed it at the
wrong type (`f(2, 40) == 42` cast a `Long` to `Integer`).  The declared return
type was recorded only for a local initialized from a closure-returning call.

## Decision

When the type checker accepts an argument of a function-value call only by
numeric widening, it records the argument (`ArgConversionSite`, with the
conversion method for the parameter type: `toLong`, `toDouble` or `toInt`).
`Lyric.Mono.desugarCheckedFile` rewrites that argument to `arg.<method>()`,
so the function receives a value of its declared parameter type. Direct
calls are unaffected: their lowering already converts to the parameter type.
A widening with no conversion method (`Byte` to `UInt`/`ULong`, or a `Float`
argument: the conversion methods exist only on `Byte`, `Int`, `Long`,
`Double` and `Char`, #2050) is rejected at the function-value call with T0043
rather than passed unconverted.

On the JVM, a local (`val`/`let`/`var`) or parameter annotated with a function
type records the type's declared return type (`recordAnnotatedFuncValRetType`),
so `lowerLambdaInvokeTail` narrows the `invoke` result to it; a `Unit` result
keeps the existing handling.

## Verification

`record_function_field_self_test.l` calls a local function value with a
literal and with an `Int` local, and a record function field with literals,
and a function-typed parameter compared against a literal, all into `Long`
parameters, on MSIL and the JVM. `typechecker_self_test.l` checks that a
`Byte` argument to a `(UInt) -> UInt` or `(ULong) -> ULong` value, and a
`Float` argument to a `(Double) -> Double` value, are T0043.
