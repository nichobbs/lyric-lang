# 2026-11-11 - TIR builder: range patterns (D574)

docs/70 phase 3a, #8613. A range pattern with literal bounds (negated ones included) builds as `TpRange`; a non-literal bound is still reported. `tir_build_self_test.l` gains a case with integer and character ranges, built and verified (130 pass). Requested by the phase 4a session, whose native lowering already consumes `TpRange`. `TpOr` over alternatives that bind nothing already builds; or-patterns that bind a name and type-test patterns (`TpTypeTest`) are still uncovered.
