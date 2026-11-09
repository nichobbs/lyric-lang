# 2026-11-09 - TIR builder: defaulted arguments (D545)

docs/70 phase 3a, #8613. A call that leaves out a literal- or constant-defaulted
parameter places the default at the call under a fresh node id. `ResolvedParam` carries
the default expression; `renumberNodeIds` numbers parameter defaults.
`tir_build_self_test.l` has 100 cases.
