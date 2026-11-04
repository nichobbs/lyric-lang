# TyParam carries its binder through GenericContext (#8747)

D337.

- `GenericContext`, `Scope` and `ResolvedSignature` record the declaration that
  binds each type parameter; the resolver builds `TyParam(name, owner)` from it,
  `substituteTyParamsOwned` replaces a parameter only for its own binder, and
  `typeEquiv` compares `(name, owner)` (an empty owner matches any binder).
- Binder keys: a function's name, `Type.member`, a type's name, `impl@file:offset`.
- Still on the empty owner: union-case and constructor field resolution,
  field-default checks, the definite-assignment pass (tracked in #8747).
- Tests: three cases in `typechecker_self_test.l`.
