# D567 - A generic call's type arguments are read from its arguments and its result together (docs/70 phase 3a, #8613)

**Status:** shipped; extends D394, D565 and D566.

## Context

The checker records the instantiation of a generic call (`genericArgsByNode`) only when every type
argument is closed. A call such as `andThenResult(Ok(value = 5), f)` leaves one parameter open at the
arguments (`E` is solved only from the expected type of the annotated result), so nothing was recorded
and the builder fell back to solving the parameters from the call's result type alone. A parameter that
appears only in an argument (`T` here) was then lost, and the body did not build.

## Decision

The fallback reads the type arguments from the argument types the checker recorded and from the call's
result type together (`genericArgsFromCall`), pairing each argument with its parameter (named arguments
by name, positional ones in the free slots) and adding the (return type, result type) pair, through the
checker's unifier `inferGenericArgsDeep` (now `pub`). An argument the checker left untyped fixes nothing.
A parameter no pair solves is still reported, never guessed.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs, on top of D566: bodies built 1080 -> 1082 of 1165,
I0003 0; `a name that is not a local` 27 -> 26. The remaining cascade comes from extern calls, distinct
conversion methods and generated-stub calls (`a.toInt()`, `Typ.GetType(..).ToString()`,
`feed.priceOf(sym)`), which are the next slices.
