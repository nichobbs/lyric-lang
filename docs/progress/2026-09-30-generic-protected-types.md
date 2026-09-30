# Generic protected types (#7830)

`protected type Cell[T] { ... }` now works on `--target dotnet` and
`--target jvm` (D147).

- MSIL lowers it to a reified generic class, like a generic record (docs/43).
- JVM erases its type parameters to `Object`, as it does for a generic
  record.
- Exclusion, `when:` barriers and invariants are unchanged.
- `--target native` reports N0007 at the declaration; per-instantiation
  native layouts are #7864.

Construction of every protected type, generic or not, is now type-checked
like a record's:
- field names (T0101) and field types (T0104) are checked;
- type arguments are inferred from the field arguments or taken from the
  expected type.

Before this, a protected-type constructor resolved to no symbol, and the
unchecked result disabled checking of every later use of the value.

Covered here, fixed on `main` by #7867: on MSIL, assigning `None` to an
`Option` field built `Option_None<object>`, so `.isNone` read `false` and a
`when: item.isNone` barrier never reopened. This affected records as well
as protected types.

Tests:
- `lyric-compiler/lyric/generic_protected_self_test.l`, 8 cases, on both
  targets. It covers inferred and expected-type construction, several
  instantiations, record and collection type arguments, a generic factory,
  an invariant, and the `None`-into-a-field regression. It is in
  `compiler-self-tests-batch.sh` and `jvm-generics-self-tests-batch.sh`.
- `protected_exclusion_{dotnet,jvm}_self_test.l`: a generic one-place
  channel handing `String`s between tasks through `when:` barriers.
