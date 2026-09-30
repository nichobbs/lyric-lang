# MSIL: narrow erased `@externTarget` arguments; instantiate generic `T[]` externs at the slice element (#7783)

An `@externTarget` wrapper's own MethodDef carries an extern-type-alias
parameter as `object`: `IEnumerableOfT[Int]`, a bracket alias
`List`1[SslApplicationProtocol]`, or an array alias `System.String[]`. The
MemberRef or MethodSpec it forwards to declares the real type. The wrapper
passed the `object` through unconverted, and ilverify rejected every such
thunk. That was 5 errors in `generic_extern_methodspec_self_test` and 7 in
`generic_extern_param_self_test`, covering `First`/`ElementAt`'s
`IEnumerable<object>`, `Array.GetValue`/`SetValue`/`Copy`/`Length`'s
`System.Array` receiver or argument, and `set_ApplicationProtocols`'s
`List<SslApplicationProtocol>`. `castErasedExternArgMsil` now narrows each
`object` argument, and the instance receiver, to the declared reference type:
a TypeRef, a closed-generic TypeSpec, a typed array, or `String`. Delegates
are left alone. An `object` BCL return that the wrapper declares as `String`
or as a Lyric class is narrowed through `narrowObjectToDeclaredTypeMsil`. The
cast cannot reject a value the call could have used, because the callee can
only reach the argument through that type.

One of the errors was a real miscompile. A generic BCL method was always
instantiated with `object`, so `Array.Empty<object>()` behind a wrapper
returning `slice[Int]` handed back an `object[]` typed `int32[]`.
`GC.AllocateArray<object>(n)` behind `slice[Int]` did the same, and its
`int32` element stores then went into an `object[]`. The new test for that
case fails under the previous compiler. `inferGenericExternWitnessesMsil` now
instantiates a type parameter that appears at a `T[]` position with the
wrapper's slice element type, when every other use of the parameter agrees.
When it cannot (`Enumerable.ToArray<T>(IEnumerable<T>)` wrapped as returning
`slice[Int]`), the build fails with F0015 instead of emitting the unsound
instantiation. The MethodSpec interning key now includes the witness types.

Scope note: a `T[]` *parameter* position still does not resolve through the
metadata scorer (`scoreSigType` requires an exact element match), so such a
wrapper fails the build with F0027 as before, rather than mis-binding. Making
it resolve means changing the scorer that auto-FFI shares, which is a
separate change.

Tests:
- `generic_extern_methodspec_self_test.l` gains
  `GC.AllocateArray<T>` over `slice[Int]` and `slice[Long]`.
- `scripts/ci/ffi-f0015-negative-test.sh` gains the `ToArray` conflict
  fixture.
- Both generic-extern self-tests verify clean and join
  `scripts/ilverify-selfhosted.sh` phase 4.
- docs/01 §11.3 documents the instantiation rule.
