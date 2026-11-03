# Generic signatures for the polymorphic builtins, docs/70 phase 3a (#8613)

D334.

- `println`, `print`, `toString` and `format1`-`format4` are typed with type
  parameters (owner `"$builtin"`) instead of `TyError`; a call instantiates them
  from its arguments (`instantiateBuiltinCall` in `typechecker_exprs.l`).
- No behaviour change for any program; the census found no builtin used as a value.
- Tests: four cases in `typechecker_self_test.l`.
