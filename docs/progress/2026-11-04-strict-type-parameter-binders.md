# Every type parameter has a binder; an empty owner is I0001 (docs/70 phase 3a, #8747)

D341. Step two of the `TyParam.owner` threading (step one: D337).

- Union-case and constructor field resolution, the field- and parameter-default
  checks, the definite-assignment pass and the interface builder now push their
  generic parameters with the declaration that binds them.
- `TyArray.sizeVar` is `Option[Type]` holding the length's `TyParam` (name and
  binder) instead of a bare name.
- `gctxPush` is gone; `gctxPushOwned` and `gctxPushEach` stop the build with
  I0001 on an empty owner, and `gctxPushEach` asserts its lists are parallel.
  `typeEquiv` and substitution no longer treat an empty owner as a wildcard.
- Receiver-pattern variables use the reserved owner `$receiver`.
- Tests: `typechecker_self_test.l` gains a direct `substituteTyParamsOwned` case
  (an inner same-named `T` is left alone) and the empty-owner equality case.
