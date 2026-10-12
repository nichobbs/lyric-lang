# `out`/`inout` value-type pointees, restored methods' by-reference parameters, and function values read from a slice on dotnet (#8206, #8210, #8299)

Three `--target dotnet` codegen bugs.  The JVM and native backends were
already correct for each.  The by-reference aliasing model (#8263) is
unchanged; only the encoding of the parameters and the stores through them
changed.

## A value-type pointee is stored with `stobj` and read with `ldobj` (#8206)

An assignment to an `out`/`inout` parameter whose type is a value type with no
`stind.*` form stored through the managed pointer with `stind.ref`.  The read
of an `inout` parameter used `ldind.ref` in the same way.  Both are only
defined for object references.  An `extern type TimeSpan = "System.TimeSpan"`
or a `Std.Time.Instant` / `Duration` parameter failed with
`InvalidProgramException` the first time the method ran.  A generic record's
`inout T` parameter instantiated at `Int`, `Long` or `Double` stored a
pointer-sized value into the caller's variable.  It ran, but only by chance.
ilverify accepted all of these, because it does not check the pointee of a
generic or extern parameter here.

Root cause: `emitLdindForType`/`emitStindForType` (`msil/lowering.l`) chose
the opcode from the pointee's `MsilType` and sent everything that is not a
primitive to `ldind.ref`/`stind.ref`.  An extern struct (`MValueTypeRef`), a
value-type generic instance (`MValueTypeGenericInst`) and a type parameter
(`MTypeVar`/`MMethodTypeVar`, whose instantiation may be a value type) now
load with `ldobj <type>` and store with `stobj <type>`.  This covers every
`MLdind`/`MStind` site: assignments to and reads of the parameter, compound
assignment, forwarding, and the copy-back of an argument passed through a
temporary.  Lyric records and `Option`/`Result` are classes on MSIL, so their
`ldind.ref`/`stind.ref` is correct and unchanged.

## A restored method's `out`/`inout` parameters are encoded by reference (#8210)

A method declared in a restored dependency (a `[dependencies]` package built to
its own DLL) was called with a MemberRef that encoded its `out`/`inout`
parameters by value, for example `setIt(Box)` where the method is
`setIt(Box&)`.  The CLR threw `MissingMethodException` when it compiled the
caller.  This affected record-body methods, `impl` methods (`inout Self` is
`object&`) and interface methods.  Free functions were already correct.

Root cause: `registerRestoredRecordMethod` and `registerRestoredIfaceMethod`
(`msil/codegen.l`) built the MemberRef signature from the bare parameter types.
They now wrap the by-reference parameters with `byrefWrapSigTypes`, as the
producer's MethodDef does.  The parameter modes were already registered, so
the call site already passed the address.

## A function value read from a slice is narrowed to its delegate type (#8299)

`val f = fs[0]` on a `slice[(Int) -> Int]` read the element through
`IList.get_Item`, which returns `object`.  The element was then stored in a
`Func`-typed local, returned as a `Func`, or invoked as one, all without a
cast.  ilverify reported this as `StackUnexpected`.  The same applied to
`fs[i](x)`, to a legacy `List<object>` read, and to a `for` loop over a slice
of `Unit`-returning functions.

The read now narrows the element to its delegate type
(`narrowObjectToFuncElemMsil`).  For a `(T1, ..., TN) -> Unit` element type
this means `Action` as well as `Func`.  A lambda literal inside a list or slice
literal whose element type is a `Unit`-returning function is now built as that
`Action` (`lowerCollElemMsil` seeds it as the other typed destinations do,
#7520).  Before this change it was built as a `Func<..., object>`.  As a
result, `val ls: List[(Int) -> Unit] = [{ a: Int -> ... }]` no longer throws
`ArrayTypeMismatchException` in `List.Add`.  A slice of such literals held
`Func`s that callers invoked as `Action`s and that worked only by chance.

## Tests

- `byref_value_type_self_test.l` (dotnet, JVM, native): `inout`/`out`
  `Instant` and `Duration`, written, read and forwarded, and a generic
  record's `inout`/`out T` at `Int`, `Long`, `Double`, `Instant` and
  `String`.  Also covers `inout Option[Int]`.
- `byref_extern_struct_dotnet_self_test.l` (dotnet): `inout`/`out` of
  `extern type` `System.TimeSpan` and `System.Guid`.
- `slice_func_elem_self_test.l` (dotnet, JVM, native): bound, direct,
  returned, two-argument, `String` and thunk function elements of a slice.
- `slice_func_unit_elem_self_test.l` (dotnet, JVM): `Unit`-returning function
  elements of a slice, indexed and iterated, and a `Unit` lambda literal in a
  `List` literal.  It does not run on native, because the native codegen does
  not yet accept a `Unit`-returning function type as a type argument (N0007).
- `scripts/ci/inout-receiver-e2e.sh` now also covers a record-body method with
  `inout` record, `out Int` and `inout Instant` parameters, and an `impl`
  method with an `inout Self` parameter.  These are called from a sibling
  package and from a restored dependency.
- ilverify (`scripts/ilverify-selfhosted.sh`) verifies the three new test
  DLLs.
