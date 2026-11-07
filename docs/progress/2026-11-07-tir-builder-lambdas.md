# 2026-11-07 - TIR builder: lambdas and captures (D399)

`Lyric.Tir.Build` builds lambdas as `XLambda`: parameters typed from the
checker's function type, the body converted to the result type, and captures
found while building (a `var` by reference, anything else by value, through every
enclosing lambda). `List`/`Map` index kinds are now told from user types by
their declaring package. `tir_build_self_test.l` is at 84 cases. See D399.
