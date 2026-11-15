# 2026-11-15 - TIR: `Type.Case` as a value (D477)

docs/70 §6.3, #8613. The checker records the case a qualified enum or nullary union case names, and the builder builds the member as that case instead of building the type name as a receiver. Self-tests: `tir_build_self_test.l` (an enum case as an argument and binding, a nullary union case).
