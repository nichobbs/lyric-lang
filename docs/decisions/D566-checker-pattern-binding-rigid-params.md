# D566 - A pattern binding keeps the enclosing function's type parameters (docs/70 phase 3a, #8613)

**Status:** shipped; extends D388 and D565.

## Context

`bindPatternTyped` bound every pattern variable at `eraseTyParams(ty)`, which replaced each type
parameter in the type with the lenient generic error type. `recordPatType` kept the real type for the
pattern node, but the variable's own uses (`f(v)` after `case Good(v)` in `func andThen[T, U, E]`)
were typed as an error, so the TIR builder could not build any body that matched a generic union
inside a generic function. The same body also lost the field signature of a construction whose field
types name a type parameter (`Bad(e = e)`), because `recordCtorSigNode` only accepted fully closed
types.

## Decision

- A pattern binding keeps the type parameters of the enclosing generic function (`Scope.genericNames`):
  they are rigid and in scope, as for a parameter or an annotated local. Any other parameter is still
  erased (`eraseTyParamsExcept`), which covers a declaration's own unsubstituted parameters.
- `recordCtorSigNode` takes the enclosing generics and treats a field type or result type naming only
  them as closed (`typeIsClosedOver`).

## Measured

The compiler and stdlib build with the stricter binding, and the typechecker self-test passes (1145).
`scripts/ci/tir-census.sh` over the 98 programs, on top of D565: bodies built 1079 -> 1080 of 1165,
I0003 0. The `a name that is not a local` cascade (27) did not move: the next root it shows is a
generic call whose instantiation the checker never records because one argument leaves a parameter
unsolved (`andThenResult(Ok(value = 5), f)` solves `E` only from the expected type), so the builder
cannot give the call its type arguments. That is the next slice.
