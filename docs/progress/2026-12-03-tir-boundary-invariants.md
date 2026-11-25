# Public-boundary invariant checks on TIR (docs/70 phase 3c)

Decision: D507.

## What shipped

- `TFnDecl.isPublic`; `Lyric.Tir.Contracts.elaborateBundleWith` adds entry checks and exit postconditions for public functions over invariant-carrying types, ungated by the contracts switch.
- `Pipeline.pipeContractsTir` takes the other visible packages; the native bridge passes them.
- `tir_contracts_self_test.l`: own-package result and `inout` re-checks (contracts on and off) and a cross-package entry check.

## Remaining

Methods and `impl` members, generic types, restored-interface checkers, protected-type invariants.
