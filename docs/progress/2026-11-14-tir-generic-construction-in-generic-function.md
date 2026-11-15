# 2026-11-14 - TIR builder: a generic record constructed at the enclosing function's own type parameter (D465)

docs/70 phase 3a, #8613. `recordCtorSigNode` no longer erases the enclosing generic's type parameters from a generic record's field types, so `One(v = x)` in `wrap[U]` and `Step(model = m, effects = es)` in `stepAll[M, E]` build. `tir_build_self_test.l` adds the case.
