# The native TIR lowering copies array elements passed by reference (docs/70 phase 4a, D871)

## What shipped

- `byRefArgCopy` in `llvm_tir.l` passes an `out` or `inout` array element through a temporary stored back after the call (D179), replacing the per-function fallback D859 kept for an element beside another by-reference argument (#9433).
- `scripts/ci/native-via-tir/elemcopy.l` and a case in `native-via-tir-e2e.sh`: the same output on both paths, and no function kept on the AST path.
