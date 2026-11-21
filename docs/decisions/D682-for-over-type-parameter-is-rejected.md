# D682 - Iterating a value of a type parameter is T0230 (docs/70 phase 3a, #8613)

**Status:** shipped; checker change, decided by the owner.

## Context

A generic body's type parameter is rigid (docs/01 section 2): only the methods its bounds promise can be called on it. The checker nevertheless accepted `for x in a` with `a: T` and left the loop variable untyped (`tyErrorGeneric`), which TIR cannot represent: it has no wildcard type (docs/70 section 5.1), and an "unknown until monomorphisation" form would defeat that rule. `fixed_array_self_test.l` held the only such program of the compiler, the ecosystem and the stdlib, as `countGen[T](a: in T)` called with arrays.

## Decision

A `for` over a value whose type is a type parameter is the error **T0230**, naming the parameter and suggesting `slice[T]` or `array[N, T]`. No bound promises iteration, so no bound makes it valid. The reject corpus case `for_over_type_param` and two typechecker self-test cases pin it; docs/01 section 2 and the book's diagnostic table say so. `countGen` takes `array[N, T]`, keeping what the test checks: one generic over arrays of two lengths gets two specialisations, and a loop over an array iterates its elements.
