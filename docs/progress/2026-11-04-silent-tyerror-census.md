# Silent TyError census and the I0001 gate decision (#8613)

D338.

- `LYRIC_TYERR_CENSUS=1` logs every expression the checker types `TyError`
  without a diagnostic (package, kind, name, position); off by default.
- Over the compiler and stdlib closure: 11,654 sites, about 90% callee
  positions; 1,161 non-callee sites to type or diagnose before the gate.
- Q-TIR-001 decided: I0001 always stops the build, callee positions exempt
  until the TIR builder.
