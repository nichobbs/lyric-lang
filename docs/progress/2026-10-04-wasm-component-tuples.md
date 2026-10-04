# wasm32 component: tuples (docs/35 W4 follow-up)

Lyric tuples are WIT `tuple<...>` in a component export (D-progress-1041), nested in lists,
options, results, records and other tuples.

- Layout reuses the record rules; shims destructure with `val (a, b) = v`.
- Test: a component exporting tuples in every position, run through `jco` under node.
