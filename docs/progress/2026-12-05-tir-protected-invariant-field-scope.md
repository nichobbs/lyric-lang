# A protected invariant reads the field, not a parameter of its name on TIR (docs/70 phase 3c, #9432)

## What shipped

- The builder builds each protected-type `invariant:` clause with only the receiver in scope (`buildInvariantClause`), so a member parameter named like a field no longer hides the field from the clause (D509). `Guard.put(level: in Int)` with `invariant: level >= 0` asserted the parameter instead of the field.
- `tir_build_self_test.l`: the member's invariant does not read the parameter's local.
