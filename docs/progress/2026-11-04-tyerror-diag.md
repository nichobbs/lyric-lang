# `TyError` carries its diagnostic (#8613)

D340.

- `TyError(diag: DiagId)` replaces the nullary case. `tyErrorSilent()`,
  `tyErrorFor(diags)` and `isSilentTyError` are the constructors and test; every
  existing construction is `tyErrorSilent()`, so behaviour is unchanged and the
  remaining silent sites are `rg tyErrorSilent`. Unit test in
  `typechecker_self_test.l`. Next: record the diagnostic per file, then the
  I0001 gate (warning, then error).
