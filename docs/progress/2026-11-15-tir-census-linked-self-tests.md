# 2026-11-15 - TIR census: linked self-tests judged by default (D475)

docs/70 §12.2, #8613. `scripts/ci/tir-census.sh` runs a self-test that fails the ordinary build under `lyric test` when it is a `@test_module` (its compiler imports resolve there), so those builds are judged instead of unchecked. `func main` programs stay unchecked, listed by name and exit code. `TIR_CENSUS_LINKED=0` and `TIR_CENSUS_SELFTESTS` control it.
