# The checker records an expression type per NodeId and `Lyric.Tir.Build` converts it (docs/70 phase 3a, D360)

First slice of the TIR builder (§6.3). `SymbolTable.exprTypes` holds the type
of every expression by `NodeId`; the new `Lyric.Tir.Build` package converts the
checker's `Type` to `Lyric.Tir.Ty` and reports I0002 for a type it cannot give.
`LYRIC_VERIFY_IR=1` numbers the file before checking and prints the I0002
census. Nothing consumes it yet. See D360; `tir_build_self_test.l`.
