# 2026-11-08 - `lyric build --verify-ir` and the TIR census gate (D542)

docs/70 phase 3a, #8613. `lyric build --verify-ir` prints the typed-IR census;
`scripts/ci/tir-census.sh` and the `tir-census` CI job build the stdlib test
programs with it and fail on any I0003 or any program they cannot judge. The first
full run (101 programs, 813 of 1165 bodies built) found three builder defects now
fixed: `out` parameters were immutable, a block ending in a jump was `Unit`, module
values had no entry, a dependency union case's payload was resolved in the reader's scope;
I0003 is 0 over the 98 programs (809 of 1165 bodies built). `tir_build_self_test.l` has 93 cases.
