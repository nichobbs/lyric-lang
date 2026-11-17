# D499 - A function returning Never used as one returning another type (docs/70 phase 3a, #8613)

**Status:** shipped; extends D319 (the typed IR).

## Context

A function value whose result is `Never` (a lambda whose body diverges, such as `{ -> panic("x") }`) satisfies a function parameter of the same shape that returns `Unit`, `Int` or any other type (`typechecker_self_test.l`, "never-returning lambda satisfies unit-function param"). The builder had no conversion between function types whose results differ, so the argument was counted as "an argument conversion" (I0002).

## Decision

`ConvKind` gains `CvNeverFn`: the operand is a function type with result `Never`, the node the same function type (same parameters and asyncness) with another result. It never returns, so the conversion changes the type only. `convertValue` builds it from the two types alone (`isNeverFnOf`), the verifier checks them (`convert-type`), and the interface format writes tag 16 (append-only).

## Results

`tir_build_self_test.l` builds a call that passes a diverging lambda as a `() -> Unit` and as a `() -> Int` with 0 I0002 and 0 I0003; `tir_verify_self_test.l` rejects other parameters and a result that is not `Never`.
