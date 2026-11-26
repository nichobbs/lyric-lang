# Protected-type invariants on TIR (docs/70 phase 3c)

Decision: D509.

## What shipped

- `TFnDecl.invariants`/`invariantTexts`, built per protected member in `build_members.l`/`build_expr.l`; asserted at every exit by `Lyric.Tir.Contracts`, contracts on or off; `Lyric.Tir.Verify` and `Lyric.Tir.Mono` carry them.
- `mapFileNodes` numbers protected-type invariant clauses.
- `tir_contracts_self_test.l`: an entry and a function of a protected type, contracts on and off.
