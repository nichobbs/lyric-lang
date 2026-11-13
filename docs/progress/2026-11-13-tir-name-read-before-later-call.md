# 2026-11-13 - TIR builder: a name read before a later call is bound to a temporary when names reorder arguments (D481)

docs/70 phase 3a, #8613, #9076 (found by the native TIR path). `two(b = x, a = zero(x))` with `zero(x: inout Int)` read `x` after `zero` had changed it; a name argument that precedes a later call argument is now bound to a temporary in source order. `tir_build_self_test.l` adds the case (183 pass).
