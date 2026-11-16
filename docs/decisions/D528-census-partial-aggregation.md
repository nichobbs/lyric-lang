# D528 - The census can aggregate a part-finished run (docs/70 phase 3a, #8613)

**Status:** shipped; extends D475 and D523.

## Context

The wide census builds hundreds of programs and takes hours (the self-tests area alone is over 1000 builds). It keeps each build's log and exit code under `TIR_CENSUS_STATE` and resumes, but it prints its per-area and per-kind tables only when every build is done. A run stopped at a time limit therefore left a full state directory and no table.

## Decision

`TIR_CENSUS_PARTIAL=1` (with `--wide` and `TIR_CENSUS_STATE`) builds nothing. It aggregates the builds already kept, skips the standard-library phase and the e2e shape scripts (neither is cached), prints how many wide builds had no kept result, and never gates. The compiler area now goes through the same cache (key `compiler-driver`), so a stopped run keeps it too. A run without `TIR_CENSUS_PARTIAL` is unchanged.
