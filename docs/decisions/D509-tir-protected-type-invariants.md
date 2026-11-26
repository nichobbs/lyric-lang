# D509 - Protected-type invariants on TIR: asserted at the exit of each member

**Status:** accepted, implemented in the TIR builder and `Lyric.Tir.Contracts` (docs/70 phase 3c, §7.2; follows D502, D505, D507)

## Decision

1. **`TFnDecl.invariants` / `invariantTexts`**: the `invariant:` clauses of the protected type a member (entry or function) belongs to, built in the member's own scope (a bare field name reads a field of the receiver, as in the member's body) with their formatter-rendered text. The builder builds each clause once per member and gives that copy node ids of its own, because the clause is one AST node tree and the verifier requires node ids unique within a package.
2. **`Lyric.Tir.Contracts` asserts them after the member's own postconditions, at every way out**, as the AST pass does (`typeInvariants` of `elaborateMember`): `InvariantViolated: Pkg.Type.member invariant <clause>`. Like D507's boundary checks they are system checks, not gated by the contracts switch (#7645).
3. **Numbering**: `Lyric.ContractElaborator.mapFileNodes` now also visits a protected type's invariant clauses, so `renumberNodeIds` gives them node ids and the checker's per-node types reach the builder (it skipped them before, leaving id 0).
4. **Native**: a member with invariants stays on the AST path unless the contract pass has elaborated it (the same guard as contracts).

## Not done

Methods and `impl` members of records, generic invariant types at the boundary, and a checker held only in a restored interface (D507's list); the record and opaque types' clauses, which have no member-level check (construction and boundary only, as on the AST).
