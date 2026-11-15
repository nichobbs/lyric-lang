# 2026-11-15 - TIR census: bodies counted once across programs (D474)

docs/70 §12.2, #8613. `lyric build --verify-ir` with `LYRIC_TIR_CENSUS_BODIES=1` prints a `TIR body` line per function body (key, built or not, uncovered kinds with counts and first site). `scripts/ci/tir-census.sh` uses them to report unique bodies and kinds per area beside the raw per-build totals, and says so when a wide area was not run. Self-test: `tir_build_self_test.l` (`bodyCensusLines`).
