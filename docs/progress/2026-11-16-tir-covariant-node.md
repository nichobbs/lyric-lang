# 2026-11-16 - TIR builder: covariant conversion of recursive unions and collections (D524)

docs/70 phase 3a, #8613. `CvCovariant` (verifier rule, interface tag 12, dump text) carries a value used at the same generic type with other type arguments that each convert, for the shapes D487/D488 cannot rebuild: a recursive union and a host collection. Checks: `tir-builder-shapes-e2e.sh` (`covariant_recursive_union_values` now builds and runs, `covariant_collection_values`), `tir_verify_self_test.l`, `covariant_conversion_self_test.l`.
