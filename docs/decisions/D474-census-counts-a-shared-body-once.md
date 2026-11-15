# D474 - The TIR census counts a body shared by several programs once (docs/70 §12.2, #8613)

**Status:** shipped.

## Context

A package that several programs share is built into each of them: the stdlib's source-loaded JVM kernels into every JVM program, the compiler's packages into every self-test. The census summed per build, so one body counted once per program and the wide self-tests number was inflated about tenfold (D473 removed the largest block, the `@externTarget` placeholders; the same applies to any shared body). The per-kind sample site (`file:line:col` of the program, not of the body) also named the wrong file.

## Decision

With `LYRIC_TIR_CENSUS_BODIES=1` and `--verify-ir` the checker prints one `TIR body` line per function body: `built` or `unbuilt` with the symbol's DefPath key (`Pkg::name(...)`, `~name` when the checker has none), and for an unbuilt body one `kind` line per uncovered kind with its node count and first `line:column` (`bodyCensusLines`, fed by new per-body `uncovered`/`sites` on `FnBuildFailure`). `scripts/ci/tir-census.sh` sets the variable and keys a body of `Std.*`, `Lyric.*`, `Msil.*` or `Jvm.*` by its path alone and any other body by its program as well; a body seen built in one program and not in another counts as not built. It reports the unique bodies and kinds (with the body key as the sample site) beside the raw per-build totals, and prints `not run here` for a wide area `TIR_CENSUS_AREAS` leaves out, so the CI run (compiler and ecosystem only) cannot read as the whole census.

## Not covered

The 365 self-tests that fail the ordinary `lyric build` are a separate change (D475).
