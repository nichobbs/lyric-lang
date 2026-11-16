# 2026-11-16 - TIR census: aggregate a part-finished run (D528)

docs/70 phase 3a, #8613. `TIR_CENSUS_PARTIAL=1 TIR_CENSUS_STATE=<dir> scripts/ci/tir-census.sh <lyric> --wide` prints the per-area and per-kind tables from the builds kept under `<dir>` without building, and says how many wide builds are missing. The compiler area is cached in the state directory like the others. Checked against a live state directory (ecosystem: 4325 of 4402 unique bodies built, I0003 0).
