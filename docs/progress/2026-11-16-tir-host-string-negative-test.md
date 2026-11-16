# 2026-11-16 - TIR builder: a `String` method no host declares stays counted (D493 follow-up)

docs/70 phase 3a, #8613. A review suggestion on #9179: `tir_build_self_test.l` pins the fallback of `buildHostMethodOnString`, that a method the host metadata declares for no host string type is not built as an extern call and stays counted (I0002).
