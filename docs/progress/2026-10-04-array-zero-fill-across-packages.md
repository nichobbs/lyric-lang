# `array[N, T]` fields: zero fill across packages and for generic records, literal inference, restored signatures (#8042)

Four limits of the first `array[N, T]` slice (D167, #7940) are lifted, on
dotnet, the JVM and native.

- **Zero fill at the construction.** An array field with no default was
  zero filled only through the default its declaring package synthesised, so
  a construction in another package had to pass it (T0105). The checker now
  records, for each construction that leaves such a field out, the field's
  zero built from its type as the construction sees it
  (`SymbolTable.arrayCtorZeroArgs`, `noteCtorZeroArgs`), and `lowerArrays`
  passes it as a named argument. This covers another package's record, a
  restored dependency's record, and a generic record, whose element type is
  known only at the construction: `Box[Int]` is filled with `0`s, and a
  `Box[String]` built without the field is T0105 naming the element type.
- **A bracket literal binds a generic record's element type.** `Box(data =
  [1, 2])` inferred no `T` (T0110). A literal's `slice[T]` type now binds an
  `array[N, T]` field's element, the literal is typed against the
  instantiated field, and it is built through a binding of that type, with or
  without an expected type around the construction.
- **Restored signatures keep their arrays.** The MSIL contract metadata was
  built from the post-mono file, where every array is already a `List`, so a
  restored consumer saw `total(a: in List[Int])` and rejected an array
  argument (T0043). A declaration whose signature mentions an array type is
  now written as declared, and the consumer lowers it to the same `List` the
  DLL member takes. Two more restored-package gaps surfaced with it: the
  contract wrote a record's `var` field without `var`, so a consumer could
  not write through it (T0157) and the record lost its identity (D157); and
  a restored generic record's `array[N, T]` field mapped to `List<object>`
  rather than `List<!0>` in the consumer's constructor reference
  (`MissingMethodException`), since `typeExprToMsilG` had no array arm.

Tests: `fixed_array_self_test.l` (generic zero fill at `Int`, `Float` and
`Bool`, literal inference) on all three targets; `fixed_array_project_self_test.l`
(another package's record and a generic record, zero filled and inferred) on
all three; the new `fixed_array_restored_self_test.l` (a dependency built to
its DLL and restored on dotnet, a path dependency on the JVM: arrays passed,
returned, zero filled and inferred); `typechecker_self_test.l`.

The JVM backend loses an unannotated generic record binding's type
arguments, so a field read through one is `Object` (#8132, not specific to
arrays); the tests annotate that binding.
