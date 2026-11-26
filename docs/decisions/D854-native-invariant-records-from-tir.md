# D854: the native TIR lowering takes records with invariants, per function

Status: accepted (docs/70 phase 4a, part 8; D520 slice 43; follows D505 and D507).

## Decision

1. **A non-generic, non-protected record that declares `invariant:` clauses is laid out for the TIR lowering like any other record.** Its constructions and `.copy` call the type's checker (D505), and a top-level `pub` function checks its parameters and result at the boundary (D507), so the functions that touch it lower from TIR instead of falling back whole.
2. **The gating is per function, not per record.** A method of a record's body or an `impl` member whose parameters or result mention a record with an invariant keeps the AST path, whose contract elaborator checks `self` and `Self` results; `TirUnitMaps.invariantRecs` carries the set (`Pkg.Name`) and `memberMentionsInvariant` decides. Generic invariant records and protected records with invariants are still not laid out for TIR, so their users also stay on the AST path.
3. `scripts/ci/native-via-tir/invariants.l` runs both ways, and `native-via-tir-e2e.sh` compiles a violated invariant and compares the `InvariantViolated` message of the two paths.

## Not done

Generic invariant records at the boundary, protected invariants (checked at each entry's return) and checkers that exist only in a restored package interface wait for the TIR passes (3c).
