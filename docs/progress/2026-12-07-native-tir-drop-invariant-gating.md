# The native TIR lowering drops its invariant gating (docs/70 phase 4a, D872)

## What shipped

- Protected types, generic records and methods or `impl` members of a type with an invariant are lowered from TIR (D509, D510, D511, D512 carry their checks); `invariantRecs`, `tyMentionsInvariant` and `memberMentionsInvariant` are gone from `llvm_codegen.l`.
- `native-via-tir-e2e.sh` expects all six functions of `invariants.l` lowered from TIR.
