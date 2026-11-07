# 2026-11-07 - TIR builder: method calls (D389)

docs/70 phase 3a, #8613. The checker records each non-generic method call's
signature, receiver type and interface (`methodCallByNode`) and the receiver's
mode on the signature (`recvMode`); `Lyric.Tir.Build` builds `XCall` with the
receiver first and a `Direct` or `Interface` callee. Mutating receivers, generic
methods and extern members stay counted I0002. Tests in `tir_build_self_test.l`.
