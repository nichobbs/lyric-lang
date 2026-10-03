# Value-generic array lengths in functions (D167 item 6, docs/67 G1)

A function's value generic parameter may size an array:
`func total[N: Nat](a: in array[N, Int]): Int`. This completes D167 item 6
for functions on `--target dotnet`, `--target jvm` and `--target native`; a
record's value generic parameter sizing an array field is #8090.

## Language

- A call binds each value generic parameter that sizes an array parameter to
  the argument's length (`total(a)` with `a: array[3, Int]` binds `N = 3`),
  or explicitly (`total[3](a)`). Two arguments that give one parameter
  different lengths, or an argument whose length is not the explicit one
  (`total[3](a)` with `a: array[5, Int]`), are **T0043**. A value parameter
  that no argument gives a length (`make()` for
  `func make[N: Nat](): array[N, Int]`) is **T0110**; `make[4]()` gives it.
- A result type that mentions `N` has the bound length, so
  `func doubled[N: Nat](a: in array[N, Int]): array[N, Int]` returns an
  `array[3, Int]` for that call and the result can be indexed, measured and
  passed on.
- In the body `N` is an `Int` constant and `a.length` is `N`.
- A length that is neither a compile-time constant nor a value generic
  parameter is **T0160** where the type is written, and a record or union
  field sized by the type's own value generic parameter is **T0160** where
  the field is declared (#8090). A later use of such an array reports only
  that its length is not known.

## Design

**Checker.** At a call to a value-generic function, `bindValueGenericCall`
matches each declared parameter type against the argument's type
(`bindArrayLengths`: through arrays, slices, tuples and generic
applications), reports conflicting lengths, records the binding in
`SymbolTable.valueGenericCallSites` (keyed by the callee's span) and gives the
result type the bound lengths (`withBoundArrayLengths`). An array parameter
whose length is a value parameter accepts an argument of any length (every
other unknown length is now T0160 at the type, so an unknown length at a call
is always a value parameter). A value-generic body is checked once over `N`:
its value parameters are `Int` locals, and the length-dependent array checks
and sites are skipped there (`inValueGenericBody`), because each
specialisation is checked again with the length bound. Calls to mixed
`[T, N: Nat]` generics record their type arguments without the value
parameters, so mono can still fill `T` from the checker.

**Mono.** The inferred-call path, previously limited to type-only generics,
now also specialises a value-generic call whose lengths the checker recorded
(`checkedValueArgsMono`), keyed by length (`total__V3`, `total__V4`). An
explicit `total[3](a)` is accepted (an integer literal index is a value type
argument). The substitution of a value parameter now covers an array length
written as `array[N, T]` (parsed as a type name) and range expressions
(`0 ..< N`). `array[N, T]` against `array[3, Int]` unifies `T`. Every value
specialisation is re-checked through the #8023 machinery and its array sites
are lowered per specialisation (`lowerSpecArrays`).

## Tests

- `fixed_array_self_test.l` (28, dotnet, JVM, native): a value-generic
  function at two lengths, an explicit length, a result typed by `N` used and
  passed on, a mixed `[T, N]` generic over `String` and `Int` arrays, and `==`
  inside a value-generic body.
- `typechecker_self_test.l` (829): a value-generic body using indexing,
  copies, `for`, `==`, `N` and `.length` checks clean; a result type gets the
  bound length and the binding is recorded; conflicting lengths are T0043; a
  non-constant length is T0160.

## Results

`fixed_array_self_test.l` 28/28 on dotnet, JVM and native;
`typechecker_self_test.l` 829/829; `mono_self_test.l` 109/109.
