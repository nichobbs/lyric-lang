# A lambda whose body ends in `try` yields the value of the `try` (docs/70 phase 3a, #8613)

**Status:** shipped; builder.

## Context

A function whose body ends in `try` builds the `try` as a value of the declared result type (the body and each `catch` assign their tail to a local). A lambda did not: its block was built with no known type, so the `try` stayed a `Unit` statement and the lambda's result was converted from `Unit`, which the builder refused (`typed_ffi_delegate_self_test.l`: a `ConnectCallback` lambda with `catch ... { panic(...) }`).

## Decision

`buildLambda` gives a body that ends in a `try` the lambda's result type, as a function's body is, when that type is not `Unit`.

## Results

`tir-builder-shapes-e2e.sh` (`lambda_ending_in_try`).
