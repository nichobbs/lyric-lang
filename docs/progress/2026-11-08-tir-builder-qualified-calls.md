# 2026-11-08 - TIR builder: qualified and static calls, out and inout arguments (D543)

docs/70 phase 3a, #8613. `Pkg.f(x)` and `Type.f(x)` build as direct calls from the
recorded callee and signature; `out` and `inout` arguments build as places. Stdlib
test census: bodies built 809 -> 913 of 1165, I0003 0. `tir_build_self_test.l` has 94
cases.
