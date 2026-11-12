# 2026-11-12 - TIR: bare field names in impl methods (D594)

A bare field of the receiver in an `impl` method (`base` in `impl Scaler for Doubler`) builds as a field read or write
of `self`: `bareSelfField` uses `fieldRefOf`, which covers records, opaque types and protected types. One test added to
`tir_build_self_test.l`.
