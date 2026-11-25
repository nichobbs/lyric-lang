# Native TIR lowering: closures over Unit values (docs/70 phase 4a)

Decision: D852. Slice 42 of phase 4a, part 7.

## What shipped

- A lambda capturing a Unit local, and a lambda or function type with a Unit parameter (`lyric-compiler/lyric/llvm_tir.l`); coverage in `scripts/ci/native-via-tir/closures.l`.
