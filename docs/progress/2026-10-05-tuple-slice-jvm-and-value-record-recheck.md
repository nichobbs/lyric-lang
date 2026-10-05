# Slices bound out of tuples; batched value-record re-check (#8147)

## A slice bound out of a tuple pattern (#8147)

A tuple's components are erased to `Object` on the JVM. A slice component
bound by a tuple pattern (`val (xs, n) = f()`, or a `match` arm) was
coerced to `Object[]` with a `checkcast`. A slice built from a bracket
literal is an `ArrayList` at runtime, so the cast failed, and indexing the
slice failed JVM verification.

An erased value reaching an `Object[]` slot now goes through a per-package
`__lyricErasedToSlice` helper, emitted only when used. It returns an
`ArrayList`'s `toArray()` and casts anything else to `Object[]`.

The same case on dotnet ran, but its IL did not verify. The bound element
was stored into a slot typed `int32[]` (or `string[]`) as an unconverted
`object`. A slice there is a real array when it was built where a slice was
expected, and a `List` otherwise (#2539). The tuple patterns now narrow such
an element with `emitObjectToSliceArrayMsil`, which keeps a real array and
copies a `List` into a fresh one. A slice is never written through, so the
copy is not observable.

`tuple_expected_type_self_test.l` adds a case covering a `match` arm, a
destructuring `val` and a `String` slice. It passes 7 on dotnet, the JVM
and native. Its dotnet DLL passes `scripts/ilverify-selfhosted.sh`.

## Value-generic records: batched re-check (#8151 review suggestions)

- `lowerValueRecordSpecs` re-checked the whole file once per record
  specialisation. It now builds the signature-only items once and checks
  the specialisations in rounds: each round holds at most one
  specialisation of each record, in full, with every other specialisation
  as a signature. A file with K instances of one record takes K checks; a
  file with one instance each of several records takes one.
- `scripts/ci/value-generic-record-e2e.sh` adds negative cases on every
  target: a length mismatch (T0060), two fields giving different lengths
  (T0043) and a type where a length is expected (T0163).
