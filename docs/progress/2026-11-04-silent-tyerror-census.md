# Silent TyError census and the I0001 gate decision (#8613)

D338.

- A temporary census of expressions the checker types `TyError` without a
  diagnostic was run over the compiler and stdlib closure: 11,654 sites, about
  90% callee positions; 1,161 non-callee sites to type or diagnose before the
  gate. The instrumentation is not merged (see D338).
- Q-TIR-001 decided: I0001 always stops the build, callee positions exempt
  until the TIR builder.
