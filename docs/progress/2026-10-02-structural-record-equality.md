# Structural `==` on records (D164, docs/67 G1, #7940)

`==` on records meant different things on different backends. Two
independently built `Point(x = 1, y = 2)` values compared unequal on dotnet
and native (reference identity), even with `@derive(Equals)`; the JVM
compared derived records structurally. D157 makes a record without `var`
fields a value, whose copying must be unobservable, and native will lower
such records by value (docs/67 §4.2), where identity does not exist.

## Rule

`==` / `!=` on a record with no `var` field, or one annotated
`@derive(Equals)`, compares field by field:

- a field that is itself such a record compares by its fields;
- a non-generic distinct type compares by its underlying value;
- any other field uses its own type's `==` (text for `String`, structural
  for a union, IEEE for `Float`/`Double`, identity for a mutable record).

A record with a `var` field that does not derive `Equals` keeps identity.
A function-typed field reached by the expansion is the new **T0153**.

## Lowering

The checker records each such operator with the member paths of its leaf
comparisons (`SymbolTable.recordEqSites`), and
`Lyric.ContractElaborator.lowerRecordEq` rewrites it after the
record-arithmetic pass into

```lyric
{
  val __lyric_req_<s>_<e>_l: R = a
  val __lyric_req_<s>_<e>_r: R = b
  l.x == r.x and l.inner.y == r.inner.y and ...
}
```

negated for `!=`. Each operand is evaluated once, left to right.

## Native union equality

`--target native` compared union values by pointer, contradicting docs/01
§2.5 (two `None`s were unequal). The native backend now synthesises
`<Union>.eq(i8*, i8*)` on first use: the same instance, or the same
discriminant with each payload field equal by its type (string text, nested
union recursively, IEEE floats, identity for other references).

## Not covered

Equality a backend runtime performs itself (`Map`/`Set` keys,
`List.contains`, record payloads inside union equality) still uses each
backend's object equality: #8003.

## Tests

- `record_eq_self_test.l` (dotnet, JVM, native). It covers value, nested,
  string, distinct, generic, empty and union-holding records; IEEE fields;
  mutable records with and without `@derive(Equals)`; single evaluation; and
  structural union equality, including nested and generic unions.
- `typechecker_self_test.l`: T0153.
