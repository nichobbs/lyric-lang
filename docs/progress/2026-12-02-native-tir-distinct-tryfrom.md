# Native TIR lowering: T.tryFrom on distinct types (docs/70 phase 4a)

Decision: D851. Slice 41 of phase 4a, part 7.

## What shipped

- `lowerTryFrom`, `buildCaseFromVals` and `TirLowerEnv.instArgs` (`lyric-compiler/lyric/llvm_tir.l`, `llvm_codegen.l`); coverage in `scripts/ci/native-via-tir/ranged.l`.
