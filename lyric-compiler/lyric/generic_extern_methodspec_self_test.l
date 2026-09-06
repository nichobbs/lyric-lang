//! generic_extern_methodspec_self_test.l — executable regression test for
//! #6581: the self-hosted MSIL backend could neither emit a
//! generic-declaring-type constructor whose parameter is itself a closed
//! generic instantiation (Gap 1), nor emit a MethodSpec-instantiated call to
//! a BCL method that is itself declared with its own generics (Gap 2).
//! Both gaps blocked `lyric-grpc`'s unary-call kernel
//! (`Grpc.Core.Marshaller<T>`'s ctor, `CallInvoker.BlockingUnaryCall<TRequest,
//! TResponse>`) — this test reproduces the same shapes against BCL-only
//! types so CI needs no gRPC package.
//!
//!   lyric test lyric-compiler/lyric/generic_extern_methodspec_self_test.l
@test_module
package Lyric.GenericExternMethodSpecSelfTest

import Std.Core
import Std.Testing

// ── Gap 1: generic-declaring-type ctor with a GENERICINST parameter ──────
//
// `System.Collections.Generic.List`1..ctor(IEnumerable`1<!0>)` — the ctor
// parameter is a CLOSED generic instantiation (`IEnumerable<T>`) over the
// declaring type's OWN generic parameter `!0`, not a bare `!0` or a plain
// named type.  `genericMemberSigToMsil` had no arm for this shape
// (`Mdr.STNamedGenericInst`), so it silently discarded the whole signature
// and the caller fell back to a MemberRef parented on the OPEN `List`1`
// TypeRef — an ECMA-335 §II.22.25 violation that faults with
// `TypeLoadException` the moment the ctor is invoked.
//
// Fixing the signature encoding alone was not enough: the Lyric argument
// for a GENERICINST-shaped position (here `source`, erased to plain
// `object` like every other generic-function slot) is statically only
// `object`, while the substituted parameter type is `IEnumerable`1<object>`
// (the `<object,…>` erasure default) — the CLR verifier rejects passing one
// where the other is expected without a `castclass`
// (`substituteDeclaringVarMsil` + the cast emitted in the arg-loading loop).
// `ilverify` against a standalone repro of this exact shape caught both the
// missing signature arm and the missing cast during development.
extern type ListOf[T] = "System.Collections.Generic.List`1"

@externTarget("System.Collections.Generic.List`1..ctor")
func newListOfFromSlice[T](source: in slice[T]): ListOf[T] = ()

@externTarget("System.Collections.Generic.List`1.get_Count")
func listOfCount[T](l: in ListOf[T]): Int = ()

test "generic-declaring-type ctor with a GENERICINST (IEnumerable<T>) parameter" {
  val src: slice[String] = ["a", "b", "c"]
  val copy = newListOfFromSlice(src)
  assertEqualInt(listOfCount(copy), 3, "List`1(IEnumerable<T>) ctor copied every element")
}

// ── Gap 2: a BCL method declared with its OWN generics (MethodSpec) ──────
//
// `System.Linq.Enumerable.Empty<TResult>(): IEnumerable<TResult>` is a
// generic METHOD (MVAR) on a non-generic declaring type: `Enumerable` has
// arity 0, so `emitGenericExternMember`'s `genericArityOfName` gate never
// fires for it (that gate is specific to a generic-DECLARING TYPE, e.g.
// `Marshaller`1` / `CallInvoker.BlockingUnaryCall<TRequest,TResponse>`'s
// case is the same family). Calling it needs an OPEN MemberRef preserving
// `!!0` plus a MethodSpec (table 0x2B) instantiating it — machinery that
// did not exist for user `@externTarget` declarations before this fix.
//
// `Enumerable.Empty<T>()` is guaranteed by the BCL to return the same
// cached singleton instance for a given `T`, so two calls compared via
// `Object.ReferenceEquals` prove the call actually reached the real,
// correctly-instantiated method (a mis-resolved or malformed call would
// either fault at load time or return two distinct empty sequences).
extern type IEnumerableOfT[T] = "System.Collections.Generic.IEnumerable`1"

@externTarget("System.Linq.Enumerable.Empty")
func emptySeq[T](): IEnumerableOfT[T] = ()

extern type ObjType = "System.Object"

test "generic BCL method with its own generics resolves via MethodSpec" {
  val a = emptySeq[String]()
  val b = emptySeq[String]()
  assertTrue(ObjType.ReferenceEquals(a, b), "Enumerable.Empty<T>() returns the cached per-T singleton")
}

// ── Gap 2 review follow-up (#6987): distinct declaring types must not ──────
// collide on the MethodSpec/MemberRef blob-interning key.
//
// `Array.Empty<T>(): T[]` is ALSO a zero-arg, one-genparam, non-generic-
// declaring-type static generic method — the exact same
// name-arity-genParamCount shape as `Enumerable.Empty<T>()` above, but on a
// DIFFERENT declaring type (`System.Array`, not `System.Linq.Enumerable`).
// `ctxInternBlob`/`internBlob` (lyric-compiler/msil/heaps.l) dedupes
// strictly by KEY STRING: before this fix, `emitGenericMethodExternCall`'s
// `openKey` omitted the declaring type entirely (`"openm_Empty_1_0"` for
// BOTH), so whichever of these two functions compiled second would
// silently receive the FIRST's MemberRef signature bytes (a `T[]`-shaped
// signature reused for a call that needs `IEnumerable`1<T>`, or vice
// versa) — a load-time `TypeLoadException`/`MissingMethodException`, not a
// build-time error. Both being present and passing in the SAME compiled
// module (they inevitably compile in declaration order) is the regression
// test.
@externTarget("System.Array.Empty")
func emptyIntArr[T](): slice[T] = ()

test "Array.Empty<T>() alongside Enumerable.Empty<T>() does not collide (#6987)" {
  val arr = emptyIntArr[Int]()
  assertEqualInt(arr.count, 0, "Array.Empty<Int>() returns a genuinely zero-length array")
}

// ── Gap 2 review follow-up (#6989): box a value-type argument, and unbox a ─
// value-type return, at a method-own-generic (witnessed-as-Object) position.
//
// `System.Linq.Enumerable.Repeat<TResult>(TResult element, int count):
// IEnumerable<TResult>` — the FIRST parameter is the method's own MVAR
// (`TResult`), not the SECOND (`int count`, a fixed non-generic parameter).
// A non-generic Lyric wrapper declaring `element: Int` for this position
// (a genuine, non-erased Lyric value type) pushes the raw `int32` bits via
// `ldarg` — the MethodSpec above always witnesses `TResult` as
// `System.Object`, so the CLR verifier rejects the unboxed value where the
// witnessed-Object parameter expects a reference unless it is `box`ed
// first (a `box`-less miscompile fails to load at all,
// `InvalidProgramException`).
//
// `System.Linq.Enumerable.First<TSource>(IEnumerable<TSource> source):
// TSource` — the RETURN is the method's own bare MVAR, also witnessed as
// `System.Object`. A non-generic Lyric wrapper declaring `Int` as its
// return type must unbox that witnessed-Object result back to a real
// `int32` before `ret`, or the CLR rejects a value-type-returning MethodDef
// that leaves an object reference on the stack. Deliberately NOT tested
// with `System.Activator.CreateInstance<T>(): T` — that method's BEHAVIOR
// (not just its representation) depends on the real `T` identity
// (`CreateInstance<T>` literally constructs a new `T`), so witnessing it as
// `object` constructs a genuine `new object()` rather than `default(int)`
// and any unboxing of that is correctly rejected at RUNTIME
// (`InvalidCastException`) — a fix limitation, not a fix bug: `First<T>`
// merely relays an ALREADY-BOXED element the caller-side list already
// stores as `object` (this codebase's own generic-collection erasure
// convention, #4601), so witnessing it as `object` changes nothing about
// which value comes back.
//
// Chaining `firstOfInt` onto `repeatInt`'s own result (both declared with
// the SAME extern type alias `IEnumerableOfT[Int]`, so no cross-alias
// upcast is needed) verifies an actual VALUE round-trips through both the
// box and the unbox correctly, not merely that neither crashes.
@externTarget("System.Linq.Enumerable.Repeat")
func repeatInt(element: Int, count: Int): IEnumerableOfT[Int] = ()

@externTarget("System.Linq.Enumerable.First")
func firstOfInt(source: in IEnumerableOfT[Int]): Int = ()

test "Enumerable.Repeat<T>/First<T> box a value-type argument and unbox a value-type return (#6989)" {
  val seq = repeatInt(42, 3)
  assertEqualInt(firstOfInt(seq), 42, "the boxed Int argument round-trips through Repeat<T> and First<T> unchanged")
}

// ── Gap 2 review follow-up (#7016): same declaring type, same name, same ──
// genParamCount, same param COUNT, but different param TYPES must not
// collide either.
//
// `System.Linq.Enumerable.ElementAt<TSource>(IEnumerable<TSource>, int)`
// and the `System.Index`-taking overload
// `ElementAt<TSource>(IEnumerable<TSource>, System.Index)` (added
// alongside Ranges) are BOTH static, non-generic-declaring-type
// (`Enumerable`), with genParamCount=1 and mParams.count=2 (source,
// position) — the exact components #6987's fix (prepending `parentRow`)
// already covers, since neither the declaring type, the name, the
// genParamCount, nor the param COUNT differ between the two overloads;
// only the second parameter's own TYPE (`Int32` vs the `System.Index`
// value-type struct) does. Before this fix, whichever of the two wrapper
// functions below compiled second silently reused the first's MemberRef
// signature bytes regardless of the mismatch, faulting at CLR load time.
@externTarget("System.Linq.Enumerable.Repeat")
func repeatStr(element: in String, count: Int): IEnumerableOfT[String] = ()

extern type SystemIndex = "System.Index"

@externTarget("System.Index..ctor")
func newSystemIndex(value: Int): SystemIndex = ()

@externTarget("System.Linq.Enumerable.ElementAt")
func elementAtInt(source: in IEnumerableOfT[String], index: Int): String = ()

@externTarget("System.Linq.Enumerable.ElementAt")
func elementAtIndex(source: in IEnumerableOfT[String], index: in SystemIndex): String = ()

test "Enumerable.ElementAt<TSource>(int) vs ElementAt<TSource>(System.Index) overloads do not collide (#7016)" {
  val src = repeatStr("z", 3)
  assertEqual(elementAtInt(src, 0), "z", "int-index ElementAt<TSource> resolves to its own overload")
  assertEqual(
    elementAtIndex(src, newSystemIndex(0)),
    "z",
    "System.Index-typed ElementAt<TSource> resolves to its own overload's signature, not the int-index one's cached blob"
  )
}

// Gap 2 review follow-up #7022 (an `async`-declared wrapper over a BCL
// method that is ALSO generic in its own right must not silently emit a
// non-unwrapped body) is covered by a dedicated build-time-decline test in
// `generic_extern_valuetype_instance_self_test.l`, which already carries the
// `Lyric.Emitter`-based harness this negative test needs (a bad extern like
// this can't be declared at THIS file's own top level: the panic fires
// during codegen of the whole test module and would abort the entire
// `lyric test` run rather than fail one assertion).
