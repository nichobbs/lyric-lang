# 2026-11-09 - TIR builder: defaulted arguments (D545)

docs/70 phase 3a, #8613. A call that leaves out a literal- or constant-defaulted
parameter places the default at the call under a fresh node id. `ResolvedParam` carries
the default expression; `renumberNodeIds` numbers parameter defaults.
`tir_build_self_test.l` has 100 cases. Stdlib census: bodies built 964 -> 965 of 1165, I0003 0; the
rest of the kind is record construction defaults and imported defaults (D545).
