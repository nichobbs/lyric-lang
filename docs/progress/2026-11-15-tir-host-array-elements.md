# 2026-11-15 - TIR builder: host arrays name their element type (D472)

docs/70 §6.2, #8613. A host member's array parameter or result is the array placeholder applied to its element, from both the JVM descriptor and the CLR signature, so a slice of `Int` passes for `int[]` (`Arrays.copyOf`) and a slice of `String` does not. The `auto_ffi_jvm_self_test.l` "no host overload fits" sites are the check.
