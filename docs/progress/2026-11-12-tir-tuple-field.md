# 2026-11-12 - TIR: tuple element access (D596)

`t.0` builds as `XTupleField(recv, index)`, verified against the tuple's arity and element type (rules `tuple-field`,
`tuple-field-type`). Tests: `tir_build_self_test.l` (one case) and `tir_verify_self_test.l` (three cases).
