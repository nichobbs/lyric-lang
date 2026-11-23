# A `return` in a lambda takes the lambda's result type (docs/70 phase 3a, #8613)

**Status:** shipped; builder only.

## Context

`lyric-game/platform/src/run.l` `renderRecording[S]` builds a body lambda declared as `(Gpu.Device) -> Result[Rendered[S], String]` and, inside it, writes `val target = match Gpu.createRenderTarget(...) { case Ok(t) -> t; case Err(m) -> return Err(error = m) }`. In a generic function the checker does not type the `Err(error = m)` operand of that `return` (its result type mentions the function's own `S`), and it records no diagnostic. The builder settles the operand of a `return` from the enclosing function's result type, but only outside a lambda (`env.lambdas.count == 0`), since a `return` in a lambda returns from the lambda; inside one the operand was left open and the gate stopped the body with I0002 (#9282, `native-backend-self-tests`).

## Decision

A lambda's frame records its result type, and a `return` inside a lambda settles its operand from the innermost lambda's result type, as a `return` in a function settles from the function's. A lambda in a concrete function was never affected: the checker types those operands itself.

## Consequences

`renderRecording` builds on native. Test: `tir_build_self_test.l` (a generic function, a lambda with a `return Err(...)` in a match arm, built and verified).
