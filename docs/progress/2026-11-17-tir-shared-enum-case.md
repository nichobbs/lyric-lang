# 2026-11-17: a bare shared enum case builds as the enum its type settled at (D446)

`On` in `func f(): Beam { On }` where `Beam` and `Ray` both declare `On` is built as `Beam`'s case: the checker settles the node's type and records no reference, so `sharedCaseRead` finds the case of that type by name. The checker is unchanged. `tir-builder-shapes-e2e.sh` gains `shared_enum_case`. Docs/70 status updated.
