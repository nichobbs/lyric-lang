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

### Every value of a `Unit`-returning function type is an `Action`

The review of the first version found the same class of bug wherever a
function value passes through an erased `object`.  A value whose static type
is `(T1, ..., TN) -> Unit` is now an `Action` everywhere it is made and
everywhere it is read:

- **Lambdas produced by `if`/`match`/block.**  A lambda literal that is a
  branch of an `if`, an arm of a `match` or the tail of a block is built as the
  `Action` its destination expects.  This applies to a return, a list or slice
  element, an annotated `val` and a call or constructor argument.  The literals
  are marked by source span (`markActionSlotLambdasMsil`).  Before, `pick(c):
  (Int) -> Unit = if c { {...} } else { {...} }` returned a `Func`, which
  failed ilverify, and putting it into a `List[(Int) -> Unit]` threw
  `ArrayTypeMismatchException`.
- **`.append`, `.concat` and `.slice` on a slice.**  The result keeps the
  receiver's `slice[e]` type when `e` has no array token, instead of the
  erased `object` it had.  The appended element and a literal `concat`
  argument are built at `e`.  `ss.append(ss[0])` on a `slice[(Int) -> Unit]`
  used to invoke the `Action` element as a `Func`, which threw
  `InvalidCastException` after the first version of this change.
- **Narrowing reads.**  `castObjectToDelegateMsil` and `castObjectToMsil` now
  narrow an `object` to `Action`/`Action`N` as well as `Func`.  This applies to
  every erased read: slice and list elements, a `for` loop, a destructured
  tuple element, `toList()`'s copy, and a function-typed argument or field.
  Invoking an `object` whose static type returns `Unit` narrows it to the
  `Action` of the call's arity (`invokeLoadedFuncValueMsil`).
- **Every lambda whose checked type returns `Unit` is built as an `Action`.**
  This is decided by the lambda's own type, not by where it goes.
  - The type checker records the result of each lambda
    (`SymbolTable.lambdaUnitSites`).
  - `Lyric.Pipeline.endUnitLambdasInUnit` ends the body of each lambda whose
    result is `Unit` in `()` before mono and before the package's generics
    are exported.
  - A specialisation of another package's generic is checked in that
    package's scope (`foreignUnitLambdaSites`), and its lambdas are marked
    the same way.
  - The MSIL backend builds a lambda that ends in `()` as an `Action`.
    Before this, three kinds of value were built as a `Func`, and reading or
    calling them as the `Action` their type is threw `InvalidCastException`:
    an unannotated `val start = { n: Int -> withIt(...) }` in a generic
    `make[T]` that another package specialises (lyric-ui's `instance`); a
    `Unit` lambda given to a generic record's `T` field; and an unannotated
    lambda ending in `xs.add(x)`.
  - A lambda whose destination already chose its delegate keeps that
    delegate: an `@externTarget` parameter (`lambdaExternDelegateRetType`) or
    an erased-generic `Func` parameter.
- **Function values the codegen knows only as `object`.**  An element of a
  container built with no element type (`val hs = [{ -> c = v }]`) can be
  either kind of delegate.  When such a value is called and its result is
  `Unit` or untracked, the call checks at runtime whether the value is an
  `Action` and otherwise calls it as a `Func`
  (`invokeErasedFuncValueMsil`).  It no longer casts to `Func` unconditionally.
- **Type checker.**  `List.add(item)`, `List.add(index, item)`,
  `List.removeAt(index)` and `Map.add(key, value)` now have the result type
  `Unit`; before, the result was unknown.  As a result, a lambda that ends in
  `xs.add(x)` is a `(T) -> Unit`, as docs/01 now states, and the backends
  build it as an `Action`.  A binding that declares another type for such a
  call's result is now T0060.

## Tests

- `byref_value_type_self_test.l` (dotnet, JVM, native): `inout`/`out`
  `Instant` and `Duration`, written, read and forwarded, and a generic
  record's `inout`/`out T` at `Int`, `Long`, `Double`, `Instant` and
  `String`.  Also covers `inout Option[Int]`.
- `byref_extern_struct_dotnet_self_test.l` (dotnet): `inout`/`out` of
  `extern type` `System.TimeSpan` and `System.Guid`.
- `slice_func_elem_self_test.l` (dotnet, JVM, native) covers function
  elements of a slice that are bound, invoked directly, returned,
  two-argument, `String` and thunks.  It also covers the slice's `.append`,
  `.slice` and `.concat`, an `if`-produced lambda, and a destructured tuple's
  element.
- `slice_func_unit_elem_self_test.l` (dotnet, JVM) covers `Unit`-returning
  function elements:
  - slice elements, indexed and iterated;
  - a `Unit` lambda literal in a `List` literal;
  - `.append`, `.slice` and `.concat` of such a slice, including an appended
    literal and an unannotated lambda ending in `log.add`;
  - lambdas that an `if` or a `match` produces for a return, a list element, an
    annotated `val` and a generic argument;
  - a destructured tuple's element.

  It does not run on native, because the native codegen does not yet accept a
  `Unit`-returning function type as a type argument (N0007).
- `scripts/ci/unit-lambda-cross-package-e2e.sh` (dotnet, JVM) covers a sibling
  package's generic `make[T]` that stores unannotated `Unit` lambdas in a
  record's function fields, and the same against the library built on its own
  (a restored dependency).  It also covers a `Unit` lambda in a generic
  record's `T` field.  `slice_func_unit_elem_self_test.l` has the
  single-package cases.
- `slice_func_tolist_dotnet_self_test.l` (dotnet only): `slice.toList()` of
  function elements.  The JVM backend does not lower `toList()` on a slice.
- `scripts/ci/inout-receiver-e2e.sh` now also covers a record-body method with
  `inout` record, `out Int` and `inout Instant` parameters, and an `impl`
  method with an `inout Self` parameter.  These are called from a sibling
  package and from a restored dependency.
- ilverify (`scripts/ilverify-selfhosted.sh`) verifies the new test DLLs.
