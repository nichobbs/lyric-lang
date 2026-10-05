# An array element can be passed to an `out`/`inout` parameter (#8180)

An element of an `array[N, T]` passed to an `out`/`inout` parameter
(`zap(arr[1], 9)`), or used as the receiver of a method whose receiver is
`self: inout` (`pts[i].reset()`), type-checked but failed in codegen on every
backend: MSIL T0120, JVM J008, native N0007. An element of an array whose
storage is a writable place is itself a writable place (docs/01 §2.7: `a[i] =
v` needs a writable place), so the call now works on dotnet, the JVM and
native. An element of a `List`, `Map`, slice, `String` or extern type is not
a place (docs/01 §2.7: "an element of a `List`, `Map` or slice is not a
writable place"), and is now rejected by the type checker instead of failing
in a backend.

**Lowering.** No target can take an element's address in the form every
target shares: dotnet and the JVM represent an array as a `List` (D167), and
the JVM passes every `out`/`inout` place through a holder that is copied in
and out. The middle end therefore lowers the call once, for every target, the
way the JVM passes any place: copy in, copy out. `Lyric.Mono.argOrderCallMono`
(the D171 argument-order rewrite) rewrites such a call into

```
{
  val __lyric_ao_<n>_x0 = i()        // the element's computed indices, at its turn
  val __lyric_ao_<n>_1 = g()         // every other non-inert argument, in source order
  var __lyric_ao_<n>_e0: T = a[__lyric_ao_<n>_x0]
  val __lyric_ao_<n>_v = f(__lyric_ao_<n>_e0, __lyric_ao_<n>_1)
  a[__lyric_ao_<n>_x0] = __lyric_ao_<n>_e0
  __lyric_ao_<n>_v
}
```

- Each computed index runs once, at the element's turn in source order
  (`bindPlaceIndicesMono`, #8171), so `?` and `await` arguments beside it are
  handled by the existing operand hoists.
- The element is read after every argument has run, as the JVM fills the
  holder of any place, and stored back when the call returns; a `?` that
  returns early, or a panic, stores nothing.
- The array is never copied: the element is read from and stored into the
  place itself, at any depth (`m[i][j]`, `r.a[i]`, an element of an `inout`
  array parameter, an element of a captured array).
- A `Unit` call keeps no value and a `Never` call stores nothing back.
- A field of an element (`cells[i].v`) was already a field place and is
  unchanged.

**Type checker.** A call passing an element place to an `out`/`inout`
parameter is recorded as an `ArgOrderSite` with the new `elemCopy`,
`elemTypes`/`elemTyped` (the temporary's annotation, from the element type)
and `resultKind` fields. All its non-inert arguments are bound in source
order, not only those up to the last `?`/`await`. Diagnostics:

- **T0085**: an element of a `List`, `Map`, slice, `String` or extern type
  passed to an `out`/`inout` parameter, whatever the parameter's type; the
  message says only an element of an `array[N, T]` is a place and how to
  write the call instead.
- **T0166**: such an element as an `inout` receiver, or an element of an
  array that may not be written. T0166 no longer points at #8180 for an
  array element; `xs[i].reset()` on a `var` array works.
- **T0157**: an array-typed element (`row(m[0])` for `m: array[2, array[3,
  Int]]`) may now be passed to an `inout array[...]` parameter when its
  array is writable; before, any element was rejected.

**Semantics.** Because the element is copied in and out, a write the callee
makes to it is seen through the array only once the call returns, and if one
element is passed twice the later argument's store is kept. This is the same
on every target; docs/01 §2.7 and §5.2 say so, and D179 records the choice, its rationale and its consequences.

**Tests.** New `inout_array_element_self_test.l` (17 cases on dotnet, the
JVM and native: `inout` and `out`, two elements of one array, a call's value
across the store, computed-index order with a trace, named arguments, an
index beside `?` and `await`, an element of a field, a field of an element,
nested elements, an array-typed element, an element as an `inout` receiver,
an element of an `inout` array parameter, `String`, `Option` and
generic-parameter elements, a `Long` index, a call propagated with `?`,
returned, or `Never`), wired into the compiler, JVM-generics and native
batches and the ilverify consumer list.
`closure_captured_var_byref_self_test.l` gains two cases for an element of a
captured array (dotnet, JVM; native still captures a `var` by value, #7891).
`typechecker_self_test.l` covers the accepted forms, the T0085 cases (`List`,
`Map`, slice), T0157 for an element of a `val` array, and T0166 for a slice
element and an element of a `val` array as receivers.

**Not covered here.** Pre-existing, independent of elements: a call through
an interface value with an `inout` parameter segfaults on native (#8185), and
an `async` function's `inout` parameter is never written back on dotnet,
for a local as for an element (#8229).
