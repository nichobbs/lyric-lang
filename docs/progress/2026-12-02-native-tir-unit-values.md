# Native TIR lowering: Unit parameters, locals and arguments (docs/70 phase 4a)

Decision: D536. Slice 36 of phase 4a, part 7.

## What shipped

- `lowerTirFunction` accepts Unit parameters, Unit locals and Unit call arguments (`lyric-compiler/lyric/llvm_tir.l`); see D536 for the representation.
- `scripts/ci/native-via-tir/unit.l` and its block in `scripts/ci/native-via-tir-e2e.sh` (AST-path comparison, expected output, AddressSanitizer).

## Verification

`native-via-tir-e2e.sh` and `native-via-tir-census.sh` pass.
