# `inout T` keeps the place's type at a literal; native `inout Self` through an interface value (#8238, #8252)

Two `out`/`inout` gaps, found while fixing #8180 and #8183.

## #8238: `inout T` bound by a place and by a literal

`takeList(b, 3)` with `b: Byte` and `func takeList[T](x: inout T, nv: in T)`
bound `T` to `Int`: both the type checker (`inferOneGenericArg`) and the
monomorphizer (`unifyArgMono`) widened the `Byte` binding to the literal's
`Int`, as they do for two `in` arguments. An `out`/`inout` parameter refers to
the caller's place (D183), so `T` is the place's type and an argument that
adapts to it never widens it. Native then specialised `takeList__Int` and
rejected the `Byte` place (`N0007`); dotnet specialised correctly but typed
the result `List[Int]`, so an array-element call (`takeList(bytes[1], 3)`)
cast a `List<byte>` to `List<int>` at run time.

Fix: `inferGenericArgsForSig` (type checker) and a pinned binding in
`unifyArgMono` (`Lyric.Mono`, keyed `"inout:" + name` in `bareBound`) bind a
bare `T` parameter declared `out`/`inout` to its argument's type, in either
argument order. Test: `inout_array_element_self_test.l`, "a generic inout T
keeps the place's type when a literal fixes T too", on dotnet, JVM and native.

## #8252: `out`/`inout Self` through an interface value on native

The call was rejected (`N0023`). It now passes the place of the interface
value through a cell: the caller retains the value's object into a stack cell
and passes the cell's address in the erased `Self` slot; a heap implementer
assigns the cell like any `inout` place (releasing the object it replaces), a
by-value implementer's vtable thunk reads the record out of the box in the
cell into a local the impl writes, boxes the result into a fresh box (the old
one may be shared by another interface value) and releases the old one. After
the call the caller boxes the cell's object with the receiver's vtable, stores
the box into the place and releases the box it replaces. `N0023` remains for
a place of another type than the interface and for an `async` method.
Tests: `llvm_inout_self_test.l` (heap and by-value implementers, `out` and
`inout`, aliasing the receiver, a shared interface value, a churn loop, under
AddressSanitizer).

## Not fixed in this group

#8204, #8371 and #8111 are not part of this change; see the pull request.
