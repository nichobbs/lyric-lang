# D872: the native TIR lowering no longer keeps invariant types on the AST path

Status: accepted (docs/70 phase 4a, part 9; D520 slice 49).

## Decision

The three gates D854 and D856 kept for invariants are removed now that TIR carries the checks (D509, D510, D511, D512):

1. A protected type with `invariant:` clauses registers its layout like any other protected type; its invariants run at each member's exit on TIR (D509).
2. A generic record with `invariant:` clauses is laid out and instantiated like any other generic record.
3. A method or `impl` member that takes or returns a record with an invariant is lowered from TIR; `Lyric.Tir.Contracts` checks `self` and the result at the public boundary (D512).

`invariantRecs`, `tyMentionsInvariant` and `memberMentionsInvariant` are deleted. `scripts/ci/native-via-tir/invariants.l` now expects every function lowered from TIR.
