# D341 - The I0001 gate in warning mode: W0036 (docs/70 5.3, phase 3a, #8613)

**Status:** step one shipped (the gate as a warning, opt in). Step two (the
error I0001) waits for the non-callee census to reach zero.

## Decision

1. **What is recorded.** `inferExpr` records every expression that returns a
   silent `TyError` (`isSilentTyError`, D340), added no diagnostic while it was
   typed, and is not a callee position, in `SymbolTable.silentTyErrorSites`
   (keyed by span and expression form, so speculative re-checks record once and
   a later real type removes the record).
2. **The callee exemption is a named predicate.** `calleePositionSites` holds the
   span of every call's callee (and the base of `callee[T](..)`), written by
   `noteCalleePosition` before the callee is typed (D338). The TIR builder
   removes it by carrying a `Callee`.
3. **The report.** `reportSilentTyErrors` (next to `reportUnsolvedTypeArgs`, at
   the end of `checkFile`) adds one warning **W0036** per site, and none when
   the file already has an error: then the `TyError` is a cascade of a reported
   one (docs/70 5.3). Placement in `checkFile` rather than beside
   `pipeVerifyTir` reuses the checker's existing diagnostic gating
   (`tcFatal`/advisory) instead of duplicating it in the pipeline.
4. **Opt in.** W0036 is listed only with `LYRIC_TYERR_GATE=1`: until the typing
   work lands, ordinary builds would warn about every `x.toString()`. `scripts/bootstrap.sh` sets it for the stage 2 closure emit and prints the
   sites (`scripts/ci/tyerr-census.sh`), so the CI stage 2 log is the census of
   the compiler and stdlib closure. (The workflow file is at its size ceiling,
   `check-workflow-size.sh`, so the wiring lives in the script.) This is a transitional census switch, not a user-facing
   off-switch: it is removed when W0036 becomes the always-on error I0001.
5. **Next.** When the census on `origin/main` has no non-callee site, W0036
   becomes the error I0001 (always on, no switch), as D338 decided.
