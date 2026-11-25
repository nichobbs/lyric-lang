# Native TIR lowering: println(), Unit text, unsigned distinct text (docs/70 phase 4a)

Decision: D539. Slice 39 of phase 4a, part 7.

## What shipped

- `println()`, `toString` of Unit and unsigned-distinct formatting in `lyric-compiler/lyric/llvm_tir.l`; coverage added to `scripts/ci/native-via-tir/unit.l`.
- Patterns that bind a Unit union field or a Unit tuple element declare a Unit local (D539 item 4).
