# 2026-11-07 - TIR builder: generic calls (D394)

`Lyric.Tir.Build` builds a call to a generic function from a non-generic body as
`Direct(sym, typeArgs)` with its arguments converted against the substituted
parameter types. The checker records each call's type arguments per `NodeId`
(`SymbolTable.genericArgsByNode`). Calls inside generic functions, generic
constructions and methods stay counted I0002. `tir_build_self_test.l` is at 67
cases. See D394.
