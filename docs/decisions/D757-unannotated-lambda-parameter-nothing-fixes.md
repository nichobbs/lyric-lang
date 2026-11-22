# A lambda parameter whose type nothing fixes is an error, T0231 (docs/70 phase 3a, #8613)

**Status:** shipped; checker. Owner decision of 2026-11-22.

## Context

`val f = { x -> false }` has no expected function type, so `x` had a hole type the checker accepted; the typed IR (D347) has no wildcard type (docs/70 section 5), and a flow-sensitive inference of `x` from the uses of `f` was considered and declined.

## Decision

A lambda that initialises a `val` or `var` binding with no type annotation and has a parameter with no annotation is the checker error **T0231** at the parameter. A lambda whose parameter types come from an expected function type (an annotated binding, a call argument, a returned value, a field) is unchanged. `func_val_local_rettype_self_test.l` annotates its three lambdas (`{ x: Int -> false }`); `typechecker_self_test.l`'s lenient case is now the T0231 case plus its annotated-binding counterpart; the reject corpus has `lambda_param_unfixed`.

## Results

The checker and reject corpus cases below; docs/01 5.4, the book (chapter 4 and appendix B) and docs/70 updated.
