# T.default() at a record, distinct type or String on TIR (docs/70 phase 3c, D887)

## What shipped

- `TFieldSig.dflt` (a literal field default), `TSymEntry.isRecord`, and the underlying type of a distinct type in its entry's `ty` (D887); the builder fills them for every record entry it makes.
- `paramDefaultAt` (`tir/mono/mono_expr.l`): `T.default()` at a `String`, a distinct type or a non-generic record becomes `""`, the wrapped zero of the underlying type, or the construction with each field at its literal default or zero. A scalar keeps the built-in.
- Native: `generic_default_named_self_test.l` via TIR lowers with no "zero value" fallback (3/3). `tir_mono_self_test.l`: the three shapes plus the scalar.
