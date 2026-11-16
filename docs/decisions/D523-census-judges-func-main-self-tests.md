# D523 - The self-tests census judges `func main` programs through `lyric run` (docs/70 phase 3a, #8613)

**Status:** shipped; extends D475.

## Context

D475 made the census judge a `@test_module` self-test that fails the ordinary build by running it under `lyric test`. The 220 `func main` self-tests (the numbered `lyric-compiler/jvm/self_test_b*.l` and `lyric-compiler/msil/msil_self_test_m*.l` programs, which import the emission libraries) have no `@test_module`, so they stayed `unchecked (exit=N)`: nothing built them, and the I0002 and I0003 counts said nothing about them.

## Decision

The self-tests area runs such a program the way `scripts/run-numbered-self-tests.sh` does, `LYRIC_LOAD_COMPILER=1 LYRIC_VERIFY_IR=1 LYRIC_TIR_CENSUS_BODIES=1 lyric run <file>`, and reads the same census lines from that run. The program also runs (about 12 s); whether it passes is the numbered runner's gate, not the census's. `TIR_CENSUS_LINKED=0` turns it off with the `lyric test` path. The area is still counts-only and resumable (`TIR_CENSUS_STATE`).
