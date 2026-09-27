# 2026-09-27 — `@proof_required` builds keep runtime contract checks

D-progress-994, #7227.

`lyric build` never runs the prover, but the contract elaborator skipped
`@proof_required` files, so an unproved `@proof_required` package had no
contract checking. The elaborator now lowers their clauses into runtime
checks like any other file; `lyric prove` still discharges them statically.
Build-time proving with per-obligation elision is tracked in #7431.
