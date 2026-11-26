# Native TIR lowers List.set, wrapping arithmetic and default() (docs/70 phase 4a, part 8)

Decision: D855.

## What shipped

- `llvm_tir.l`: `List.set` (`lyric_list_set`), `wrappingAdd/Sub/Mul/Neg` as unchecked two's complement operations, `default()` for scalars and references.
- `scripts/ci/native-via-tir/wrapping.l` and a `wrapping` section in `native-via-tir-e2e.sh`: every function from TIR, same output as the AST path.

## Remaining

`String.split`, `format1`/`format2`, `array.toSlice`; `String.normalize` stays a panic on both paths.
