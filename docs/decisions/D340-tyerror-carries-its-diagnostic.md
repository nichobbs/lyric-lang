# D340 - `TyError` carries its diagnostic (docs/70 5.1, phase 3a, #8613)

**Status:** step one shipped: the data change. Recording the diagnostic at each
construction site follows, file by file; the I0001 gate (D338) comes after.

## Context

docs/70 5.1 makes `TyError` carry the diagnostic that caused it so that the I0001
gate can tell a reported error from a silent one. D338 measured 11,654 sites
that produce a `TyError` with no diagnostic. Those sites have to be findable by
name before they can be typed or diagnosed.

## Decision

1. **`TyError(diag: DiagId)`.** `DiagId` is a record `{ index: Int }`: the 1-based
   position of the causing diagnostic in the checker's diagnostic list, 0 for
   none. `typeEquiv` still treats `TyError` as the cascade-suppressing wildcard,
   whatever its `DiagId`.
2. **Named constructors.** `tyErrorFor(diags)` is a `TyError` caused by the
   diagnostic most recently added to `diags`; `tyErrorSilent()` is a `TyError`
   with no recorded diagnostic; `isSilentTyError` tests for it. A bare `TyError`
   is no longer constructible.
3. **Slicing.** Every existing construction became `tyErrorSilent()` and every
   pattern `TyError(_)`, behaviour-preserving. Each later slice replaces the
   `tyErrorSilent()` calls of one file that immediately follow a `diag.add(...)`
   with `tyErrorFor(diag)`; `rg tyErrorSilent` is the remaining inventory. The
   rest are the sites D338 counted (callee positions, unsolved holes, builtin
   member results) and go away with the typing work and the TIR builder.
