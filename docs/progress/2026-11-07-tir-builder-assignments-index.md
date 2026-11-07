# 2026-11-07 - TIR builder: assignments and index expressions (D398)

`Lyric.Tir.Build` builds assignments to locals, record fields and elements as
`XAssign` with a `TPlace` and an `AssignKind`, and index expressions as `XIndex`
with an `IndexKind` (array, slice, string, `List`, `Map`). Assignments through
`self`, to host members and record `index` methods stay counted.
`tir_build_self_test.l` is at 82 cases (the `List`/`Map` kinds, whose types need
the stdlib, are exercised by the compiler census rather than the unit test).
See D398.
