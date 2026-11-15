# 2026-11-15 - TIR builder: Exception.typeName and the Result/Option projections (D471)

docs/70 §6.2, #8613. The two shapes the wide census named under "a member access that is not a record field" are built-in property reads: `e.typeName` on a catch-bound exception and `r.value`, `r.error`, `o.value` on `Std.Core`'s `Result` and `Option` (the contract projections). Covered by a `tir_build_self_test.l` case for `typeName`; the `Result`/`Option` reads are checked against `result_ensures_accessor_self_test.l` through `--verify-ir`.
