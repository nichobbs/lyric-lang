# 2026-11-12 - TIR: host boxing, narrowing and Single (D597)

A host call's argument is now `CvBoxToHost` when the host parameter is `object`, a small host integer (`Int`/`Long`
narrowed with a range check) or `System.Single` (from a `Float`). The overload score ranks it below every widening. Tests:
`tir_build_self_test.l` (two cases) and `tir_verify_self_test.l` (one).
