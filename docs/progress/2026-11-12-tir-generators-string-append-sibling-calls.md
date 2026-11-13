# 2026-11-12 - TIR builder: generator bodies, `String +=`, bare sibling calls, `default()` and `wrapping*` (D590)

docs/70 phase 3a, #8613. Four kinds the wide census counted: an `async func` that yields (`TFnDecl.isGenerator`; the body is not a value of the yield type), `s += <non-String>` (appended as `toString`), a bare call of a sibling method (called on the enclosing `self`) and `default()` / `wrapping*` (recorded as builtins). `argument conversion` now reports its site and type pair. `tir_build_self_test.l` adds five cases (171 pass).
