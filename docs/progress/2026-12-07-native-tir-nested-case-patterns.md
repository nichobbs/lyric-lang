# The native TIR lowering takes nested case patterns (docs/70 phase 4a, D873)

## What shipped

- `patTestU` tests a case field's sub-pattern through `patTestAny` and `patBindU` binds it through the new `patBindAny`, so a case pattern under another one lowers from TIR.
- `scripts/ci/native-via-tir/nestedpat.l` and a case in `native-via-tir-e2e.sh`: the same output on both paths, and no function kept on the AST path.
