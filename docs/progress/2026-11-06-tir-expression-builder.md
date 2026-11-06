# 2026-11-06 - The expression builder builds its first kinds (D366)

`Lyric.Tir.Build.buildFnBody` builds non-generic function bodies for literals,
locals, tuples, lists, interpolation, primitive and short-circuit operators,
`if`, blocks and the structural statements; every other kind is an I0002 line
counted by kind. `LYRIC_VERIFY_IR=1` prints the builder census (20 of 1148
function bodies over the stdlib tests, calls first among the missing kinds).
Nodes typed against an expected type and `if`/`match` typed from block tails now
record their type. `tir_build_self_test.l` has 19 cases.
