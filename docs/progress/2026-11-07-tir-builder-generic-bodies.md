# 2026-11-07 - TIR builder: generic function bodies (D395)

`Lyric.Tir.Build` builds the bodies of generic top-level functions, binding the
function's type parameters to its resolver symbol so `T` converts to
`TParam(sym, index)` and a generic call inside one carries the enclosing
parameter as its type argument. `tir_build_self_test.l` is at 68 cases. See D395.
