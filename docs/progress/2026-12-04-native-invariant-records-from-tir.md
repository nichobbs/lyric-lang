# Native TIR lowers records with invariants (docs/70 phase 4a, part 8)

Decision: D854.

## What shipped

- `llvm_codegen.l`: non-generic, non-protected records with `invariant:` clauses get a TIR layout; methods and `impl` members that mention one fall back per function (`memberMentionsInvariant`).
- `scripts/ci/native-via-tir/invariants.l` and an `invariants` section in `native-via-tir-e2e.sh`: same output on both paths, same `InvariantViolated` message when violated.

## Remaining

Generic and protected invariant records, then the other items on #8613's inventory.

## Also (D855)

`List.set`, the wrapping integer methods and `default()` lower from TIR; `scripts/ci/native-via-tir/wrapping.l` and a `wrapping` section in `native-via-tir-e2e.sh` pin them.
