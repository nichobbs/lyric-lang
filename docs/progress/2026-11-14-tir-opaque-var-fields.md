# 2026-11-14 - TIR builder: an opaque type's var fields stay assignable after a construction (D464)

docs/70 phase 3a, #8613. Regression fix for D462 found by the wide census (I0003 `assign-mutable` in lyric-testing and `projectable_jvm_self_test.l`): `varFieldNames` now lists an opaque type's `var` fields. `tir_build_self_test.l` adds the case.
