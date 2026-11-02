# A slice element write is T0157 (#8394)

docs/01 §2.7 says a `slice[T]` has no in-place mutation, but the type checker
accepted `xs[i] = v` and `xs[i] op= v` on a slice, and on dotnet and the JVM
the write was seen through every binding of the slice, including a caller's
`in` argument. `checkArrayElementWrite` now reports **T0157** for an element
write whose receiver is a slice ("a slice is never written in place; use an
`array[N, T]` or a `buffer[T]`, or build a new slice"). Rebinding a slice
(`xs = xs.append(v)`, through an `inout` parameter too) is unchanged, and an
element of a slice was already not a by-reference argument (T0085).

A sweep with `lyric check` over every manifest (the compiler, the full stdlib,
every ecosystem library and example) and every test file found slice element
writes only in tests. Those that pinned codegen shared with arrays (the JVM
`JArray` store and compound-assign arms: #6169, #6741, #7005, #7341, #7343)
now use `array[N, T]`; `inout_slice_self_test.l` rebinds the `inout` slice
instead of writing elements; the two writes in
`slice_fastpath_listbacked_dotnet_self_test.l` were deleted, since the MSIL
`IList` store fallback they covered is no longer reachable. Book chapter 4's
`swap` example takes an `array[N, Int]`.

Converting `slice_fastpath_self_test.l` exposed a JVM bug: `val s =
a.toSlice()` on an `array[N, Char]` lost the slice's element type, so `s[i] ==
'c'` unboxed a `Character` as an `Integer`. The middle end ends `toSlice()`
with `out.toArray()` on a block-local list, and `blockTrailingGenericArgs`
followed a block-local binding only when the tail was the bare local; it now
also follows an element-preserving intrinsic on one (`toArray`, `append`,
`concat`, `slice`).

The verifier keeps a slice element read as a fresh value (#8728): a kernel
extern can still fill a slice in place (`streamReadInto`).

Tests: `typechecker_self_test.l`, "a slice element is never written in place:
T0157"; the converted suites on dotnet, the JVM and native.
