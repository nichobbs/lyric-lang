# 2026-11-15 - TIR: XValueParam, the read of a value-generic parameter (D467)

docs/70 §6.2, #8613. The owner chose a value-generic parameter kind in the TIR over specialising before it. `Lyric.Tir` gets `XValueParam(owner, index)`, `Lyric.Tir.Verify` the `value-param` rule (own function, a value parameter, type equals its `valueTy`), `iface_dump` prints it, and `llvm_tir.l` refuses it by name until phase 3c. The builder side (filling `valueTy`, building a bare `N` in an `impl` method) is the next change.
