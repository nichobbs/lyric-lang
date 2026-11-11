# 2026-11-11 - TIR builder: named arguments that reorder evaluation (D575)

docs/70 phase 3a, #8613. A call whose names reorder its arguments builds: each non-plain `in` argument is bound to a temporary in source order and the call takes the temporaries, inside an `XBlock` (a method call's receiver is bound first). `tir_build_self_test.l` replaces the "refused" case with a "builds" case and adds one checking the temporaries and their order (130 pass). The wide census was not re-measured.
