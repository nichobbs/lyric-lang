# D499 - A function returning Never used as one returning Unit (docs/70 phase 3a, #8613)

**Status:** shipped; extends D319 (the typed IR).

## Context

A function value whose result is `Never` (a function that always panics or loops) is accepted where a function returning `Unit` with the same parameters is expected. The builder had no conversion for a function type whose results differ, so the argument was counted as "an argument conversion" (I0002).

## Decision

`ConvKind` gains `CvNeverFnAsUnit`: the operand is a function type with result `Never`, the node the same function type with result `Unit` (same parameters and asyncness). It never returns, so the conversion changes the type only. `convertValue` builds it from the two types alone, the verifier checks them (`convert-type`), and the interface format writes tag 16 (append-only).

## Results

`tir_build_self_test.l` builds `run(stop)` with `stop: func(): Never` passed as `func(): Unit` with 0 I0002 and 0 I0003; `tir_verify_self_test.l` rejects other parameters and a non-Never result.
