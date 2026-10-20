# The `Plain` marker (docs/67 G2, #7941)

`where T: Plain` is now a checked constraint. `Plain` is computed from a
type's structure (`type_checker/typechecker_plain.l`), never declared: the
numeric scalars, `Bool`, `Char`, enums, a distinct type over a `Plain` type
with no range clause, a record with no `var` field and no `invariant:` whose
fields are all `Plain`, and an `array[N, T]` of a `Plain` element.

- A call whose type argument is not `Plain` is T0108, and the message names
  the defeating part (`field 'inner' of 'Outer' is not 'Plain': 'String' is a
  reference ...`), including the `tryFrom` hint for range subtypes and
  invariant-carrying records, and the representation-privacy reason for opaque
  types.
- `@derive(Plain)` is T0172.
- A type parameter that is itself `Plain`-bounded passes through unchanged.

Tests: five cases in `typechecker_self_test.l`. Still open under #7941:
`buffer[T]` itself, `Std.Buffer`, the managed and native lowerings, the
verifier model, `withPointer`/`withMutPointer`, and the lint rule.
