# Native TIR lowers opaque handle types and bundled construction checkers (docs/70 phase 4a, part 8)

Decision: D856.

## What shipped

- `llvm_codegen.l`: records with a custom destructor get a TIR layout; `instantiateTirOnlyFn` lowers a bundled package's `__lyric_checked_T` from its TIR declaration on first use (`Ctx.tirOnlyFns`).
- `LYRIC_NATIVE_TIR_TRACE=1` lists each fallback function with its reason.
- `scripts/ci/native-via-tir/stdinvariants.l` and a `std invariants` section in `native-via-tir-e2e.sh`.

## Remaining

The other fallback roots the trace names: calls with no IR name for other TIR-only functions, `format1`/`format2`, `String.split`, interface method `get`, `Url.tryFrom` (check after this lands).

## Also (D857)

`mapGet` and `mapSize` lower from TIR as intrinsics (`scripts/ci/native-via-tir/mapget.l`, an ASan section in `native-via-tir-e2e.sh`). The "no IR name" fallback names its callee, and a bundled checker's declaration is found in its own unit's TIR package.
