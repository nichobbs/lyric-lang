# 2026-11-15 - TIR builder: value-generic parameters (D469)

docs/70 §6.2, #8613. `TTypeParam.valueTy` is `Int` for `N: Nat` (the read type, docs/01) and a bare `N` in a function or a protected type member is `XValueParam`. The checker needed no change: it already binds the parameter as an `Int` local; the builder resolves the name against the declaration's value parameters. Covered by two `tir_build_self_test.l` cases.
