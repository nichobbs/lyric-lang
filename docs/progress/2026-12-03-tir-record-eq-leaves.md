# Record equality on TIR: array and Float leaves (docs/70 phase 3c)

Decision: D506.

## What shipped

- `buildRecordEq` (`lyric-compiler/lyric/tir/build/build_expr.l`) expands array leaves element by element (plain, distinct, Float, record and nested-array elements) and Float/Double leaves with the NaN rule.
- `tir_build_self_test.l`: Float leaf, array leaf, and Float/record/nested-array element cases, each verified by `Lyric.Tir.Verify`.

## Remaining

Records holding a tuple or union that holds an array keep the single `IoEq`/`IoNeq`.
