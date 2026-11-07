# 2026-11-07 - TIR builder: names that are not locals (D368)

docs/70 phase 3a, #8613. The checker records the declaration each non-local name
resolved to (`SymbolTable.refByNode`, keyed by `NodeId`); `Lyric.Tir.Build` builds
`XGlobal` for vals, consts and non-generic function values and `XConstruct` for
nullary union and enum cases. Four cases in `tir_build_self_test.l`.
