# The native TIR lowering takes `toString` of an enum (docs/70 phase 4a, D874)

## What shipped

- `lowerEnumToString` in `llvm_tir.l` switches on the ordinal to the case name; the code generator passes `enumNames` (`enumCaseNames` in `llvm_codegen.l`) to the lowering.
- `keptast.l` and `native-via-tir-e2e.sh`: the enum fallback is no longer expected, and a regression to it fails the e2e.
