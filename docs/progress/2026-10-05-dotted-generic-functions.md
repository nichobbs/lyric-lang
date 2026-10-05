# Generic functions named after a record (#8173)

A generic function named after a record, such as
`func Box.get[T](self: in Box[T]): T` or
`func Ints.sum[N: Nat](self: in Ints[N]): Int`, now runs on dotnet, the
JVM and native. Both call forms work: the method call `b.get()` and the
type-qualified call `Box.get(b)`.

## Before

The checker accepted both forms, but `Lyric.Mono` specialises a generic call
only when the callee is a bare name. Neither form was rewritten, so each
backend reached an unspecialised generic:

| Form | dotnet | JVM | native |
|---|---|---|---|
| `b.get()` | "unsupported method" at run time | `NoSuchMethodError` | N0007 |
| `Box.get(b)` | `InvalidProgramException` | run-time error | N0007 |

`Box.get(b)` was also never type-checked: the callee parsed as a member of a
type name, which the checker typed as an error without a diagnostic. So
`Box.get(b, 1, 2)` and a wrong argument type compiled.

## Change

- **Checker.** A type-qualified call `Box.get(args)` resolves to the
  dot-named function's signature, so its arguments are checked (T0042,
  T0031, ...). The checker records each call of a generic dot-named
  function in either form, with the type and value arguments it inferred.
- **Pipeline.** Before monomorphisation, `rewriteDottedGenericCalls`
  rewrites each recorded call to a direct call of the function, the
  receiver first for a method call. `Lyric.Mono` then specialises it like
  any generic call.
- **JVM.** A static call to a specialisation of a dot-named function uses
  its legal JVM method name, not the dotted Lyric name.
- **`self` parameters.** In a free function whose first parameter is named
  `self`, `self` now has the parameter's declared type. It was the lenient
  placeholder `Self`, so `self.data` was untyped: an array field read off
  it was never recorded as an array site, and native rejected `for` over
  it.
- **JVM: functions over a value-generic record instance.** A non-generic
  function taking or returning an instance (`func total(v: in Ints[3])`) is
  emitted over the specialised class `Ints__V3`, but its signature was
  registered from the parsed file, where `Ints[3]` erased to `Object`, so
  every call failed with `NoSuchMethodError`. The bridge now re-registers
  such functions from the specialised file, replacing the erased entry
  (registration is otherwise first-wins).

## Tests

`dotted_generic_func_self_test.l` runs on dotnet, the JVM and native: method
and type-qualified calls over type and value parameters, extra arguments
after the receiver, `for` and index reads over `self.data`, and
non-generic functions taking `Ints[3]`, through a `self` parameter and an
ordinary one.
