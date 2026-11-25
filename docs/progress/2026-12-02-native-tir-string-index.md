# Native TIR lowering: the raw String.indexOf and String.lastIndexOf (docs/70 phase 4a)

Decision: D853. Slice 43 of phase 4a, part 7.

## What shipped

- The raw `indexOf`/`lastIndexOf` builtins in `lowerStringMethod` (`lyric-compiler/lyric/llvm_tir.l`); coverage in `scripts/ci/native-via-tir/builtins.l`.
