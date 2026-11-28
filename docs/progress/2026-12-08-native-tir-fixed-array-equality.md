# The native TIR lowering takes fixed-array equality (docs/70 phase 4a, D876)

## What shipped

- `lowerAggregateEquality` in `llvm_tir.l`: `==` and `!=` on a fixed array of scalars, element by element.
- `keptast.l` and `native-via-tir-e2e.sh`: the aggregate-operator fallback is no longer expected; equal and unequal arrays are pinned and a regression to the AST path fails the e2e.
