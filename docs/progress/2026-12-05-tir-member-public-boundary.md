# Methods and impl members are public invariant boundaries on TIR (docs/70 phase 3c)

Decision: D512.

## What shipped

- `MemberSite.isPublic` (a method of a `pub` record, every `impl` member) sets `TFnDecl.isPublic`, so D507's boundary invariant checks now apply to methods and `impl` members on TIR as they do on the AST path.
- `tir_contracts_self_test.l`: a `pub` record's method and an `impl` member re-check an `inout` parameter, a record that is not `pub` does not.
