# 2026-11-15 - TIR: array copy and zero value (D489)

docs/70 phase 3a and 4a, #8613. `XArrayCopy(inner)` is built where the checker's `arrayCopySites` records a stored array, and `XZeroValue(ty)` initialises an array `var` written without an initializer, so the native backend can lower arrays of references from TIR (D520). Verifier rules `array-copy` and `zero-value`; no interface format change. `tir-builder-shapes-e2e.sh` adds `array_copy_and_zero`; `tir_verify_self_test.l` three cases.
