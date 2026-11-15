# D491 - A float literal where a Float is expected is a Float literal (docs/70 phase 3a, #8613)

**Status:** shipped; extends D396.

## Context

`makeFloatFlag("ratio", 0.5)` passes a float literal to a `Float` parameter. The checker accepts it: an unsuffixed float literal takes the `Float` its position expects, and records the literal's own type (`Double`) at the node. `convertValue` had no conversion from `Double` to `Float` (TIR's numeric conversions only widen), so the builder counted an argument conversion (four sites in `lyric-conformance` and `lyric-testing`).

## Decision

In `convertValue`, a float literal (`XLit(TLFloat)`) of type `Double` used where a `Float` is expected is the same literal at type `Float`: no conversion node, because a literal is not a computed `Double` that has to be narrowed. Rounding the value to 32 bits is the backend's lowering of a `Float` literal. Any other `Double` used as a `Float` is still counted.

## Results

`tir-builder-shapes-e2e.sh` gains `float_literal_argument` (a literal passed to a `Float` parameter and compared, built with `--verify-ir`, exits 5). The four "argument conversion from Double to Float" sites in `lyric-conformance` and `lyric-testing` are gone; 0 I0003.
