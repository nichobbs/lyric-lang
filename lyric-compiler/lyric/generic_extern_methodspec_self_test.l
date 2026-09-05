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
