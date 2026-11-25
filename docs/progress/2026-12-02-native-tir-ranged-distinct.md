# Native TIR lowering: range-checked distinct types (docs/70 phase 4a)

Decision: D538. Slice 38 of phase 4a, part 7.

## What shipped

- Range-checked distinct types, the range check on `T.from` and on derived arithmetic, and operators on distinct types that follow the wrapped primitive (`lyric-compiler/lyric/llvm_tir.l`, `llvm_codegen.l`).
- `scripts/ci/native-via-tir/ranged.l` and its block in `scripts/ci/native-via-tir-e2e.sh`.

## Remaining

`T.tryFrom` on a distinct or range type.
