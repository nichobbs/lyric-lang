# TIR builder: Char widens to int at a host call; the most specific equal-score overload wins (D697)

`sb.charAt('a')` and `Math.abs(byte)` resolve as the host resolves them. `auto_ffi_jvm_self_test` builds 61 of its 70 bodies (was 59). A slice passed for a host varargs `Object[]` stays counted pending a design decision (D697). Self-test: `tir_build_self_test.l`.
