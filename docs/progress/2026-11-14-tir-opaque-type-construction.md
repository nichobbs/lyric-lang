# 2026-11-14 - TIR builder: an opaque type is constructed by its fields inside its own package (D462)

docs/70 phase 3a, #8613. The checker records the field signature of a non-generic opaque type's construction (`ctorSigByNode`), so `SqlText(text = t, placeholders = n)`, `StringBuilder(host = h)` and `SubsegmentHandle()` build. `tir_build_self_test.l` adds two cases. `scripts/ci/tir-census.sh` also gains `TIR_CENSUS_STATE=<dir>` to resume a wide census.
