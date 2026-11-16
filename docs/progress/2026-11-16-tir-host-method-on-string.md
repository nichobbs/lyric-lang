# 2026-11-16 - TIR builder: a host method called on a `String` value (D493)

docs/70 phase 3a, #8613. `s.compareTo(t)` and the other `java.lang.String` methods the JVM kernels call on a Lyric `String` build as extern calls with the value as receiver, found through the host metadata (`buildHostMethodOnString`). Self-test: `tir_build_self_test.l`. Withdrawn on the way: typing a host class result as its extern type (#9175), which contradicts docs/01 section 2.11.
