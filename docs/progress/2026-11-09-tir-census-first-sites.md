# 2026-11-09 - TIR census: where each uncovered kind was first met (D550)

docs/70 phase 3a, #8613. The builder remembers the first `line:column` of each kind it has
no case for and `scripts/ci/tir-census.sh` prints one sample file site per kind. The
samples show that the largest kinds are protected-type entry calls and qualified built-in
calls (a checker gap), and that `a name that is not a local` is only a cascade.
`tir_build_self_test.l` has 101 cases.
