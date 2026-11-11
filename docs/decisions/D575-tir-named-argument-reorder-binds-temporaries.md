# D575 - Named arguments that reorder evaluation bind temporaries (docs/70 phase 3a, #8613)

**Status:** shipped; extends D361 and D567.

## Context

Arguments are evaluated in the order written, but a TIR call lists them in parameter order. When names put them in a different order (`k(b = f(), a = g())`), building the call in parameter order would run `g()` before `f()`. The builder refused any such call unless every argument was a literal or a name, and counted the rest as `a call whose named arguments reorder effects` (103 sites in the compiler area, D571).

## Decision

- When names reorder the arguments, each `in` argument that is not a literal or a name is bound to a fresh temporary local in source order (`TsLet` of a `TpBind`), and the call takes the temporary. The call is wrapped in an `XBlock` whose statements are those bindings.
- A method call's receiver is evaluated before any argument: when arguments were hoisted and the receiver is not a literal or a name, the receiver is bound first.
- Calls whose arguments are in parameter order, or whose reordered arguments are all plain, build as before, with no block.
- The same rule applies to function, method and construction calls (they share `buildCallArgs`).

## Measured

The `tir_build` self-test passes (130), with a case that checks the temporaries and their order and a verifier run over the result. The wide census was not re-measured for this change.
