# Phase 3c reviewer-suggested test gaps (docs/70 phase 3c, D519, D514, D881)

## What shipped

- `tir_contracts_self_test.l` (D519): the entry check of a generic parameter is called at the function's own type parameter (not a closed type); a two-argument generic type is checked at both arguments in order; a nested generic argument is checked at the closed nested instance.
- `tir_mono_self_test.l` (D514): the full instance keys of an impl member with type parameters of its own are asserted (`pick` at the impl's argument and its own, `get` at the impl's argument alone), and `pick` is not a member of the impl instance.
- `typechecker_self_test.l` (D881): a negated literal outside the annotated type is still T0015 (`val a: Byte = -200`), and `val n: Float = -0.1` checks clean.

Not covered here: D882's `bundledTirOf` test for an `internal` cross-package call (needs the native bridge fixture; left on the inventory), and a negative case for D514's "fewer parameters" path (no program in the corpus reaches it).
