# `TyError` records its diagnostic, slice 1 (#8613)

D340.

- The 44 `tyErrorSilent()` constructions that directly follow a
  `diag.add(errorDiagnostic(..))` / `warningDiagnostic(..)` (32 in
  `typechecker_exprs.l`, 10 in `typechecker_resolver.l`, 2 in
  `typechecker_stmts.l`) are now `tyErrorFor(diag)`. Behaviour is unchanged
  (`typeEquiv` ignores the id); `rg tyErrorSilent` now lists 201 sites, the
  callee positions, unsolved holes and builtin member results D338 counted.
- `scripts/ci/tyerr-census.sh` says how many sites it did not print past 2000.
