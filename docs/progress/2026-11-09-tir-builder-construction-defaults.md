# 2026-11-09 - TIR builder: record construction defaults (D546)

docs/70 phase 3a, #8613. A record construction that leaves a literal- or constant-
defaulted field out places the default at the construction, as a call does for a
parameter (D545). `a defaulted argument` 76 -> 0 in the stdlib census; bodies built stay
at 965 of 1165 because those bodies reach their next kind. Review notes on D545 fixed
(displaced doc comments; a missing default type is an I0002). `tir_build_self_test.l`
has 100 cases.
