//! generic_extern_self_test.l — regression test for generic `@externTarget`
//! members whose *declaring type* is a generic BCL type (#3392).
//!
//! A member of a generic type cannot be referenced through an open-generic
//! TypeRef with a concrete-typed signature (ECMA-335 §II.22.25); the
//! self-hosted MSIL emitter now emits a closed `<object,…>` GENERICINST
//! TypeSpec parent with a `!0`/`!1`-encoded member signature, casts the
//! receiver to it, boxes value-type arguments, and marshals `out` arguments
//! across the erasure boundary.  Before the fix the monomorphizer dropped the
//! `@externTarget` annotation, leaving an `ldnull; ret` stub — invalid IL for a
//! `Unit` return and a silent always-`false` for `Bool` (the rate-limiter /
//! circuit-breaker no-op of #3392).
//!
//! Run by native `lyric test` (compiles in-process through the self-hosted
//! Msil.Bridge and asserts every runtime value).  Imports only `Std.*`; the
//! generic `ConcurrentDictionary`2` externs are declared inline.
//!
//!   lyric test lyric-compiler/lyric/generic_extern_self_test.l
@test_module
package Lyric.GenericExternSelfTest

import Std.Core
import Std.Testing

extern type CD[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

extern type Tup[A, B] = "System.Tuple`2"

// Unquoted generic type declarations (omitting backtick and arity suffix)
extern type UnquotedCD[K, V] = System.Collections.Concurrent.ConcurrentDictionary
extern type UnquotedTup[A, B] = System.Tuple

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newCD[K, V](): CD[K, V] = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdGet[K, V](dict: in CD[K, V], key: in K, value: out V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func cdAdd[K, V](dict: in CD[K, V], key: in K, value: in V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.set_Item")
func cdSet[K, V](dict: in CD[K, V], key: in K, value: in V): Unit = ()

@externTarget("System.Tuple`2..ctor")
func newTup[A, B](a: in A, b: in B): Tup[A, B] = ()

@externTarget("System.Tuple`2.ToString")
func tupToString[A, B](t: in Tup[A, B]): String = ()

@externTarget("System.Tuple`2..ctor")
func newUnquotedTup[A, B](a: in A, b: in B): UnquotedTup[A, B] = ()

@externTarget("System.Tuple`2.ToString")
func unquotedTupToString[A, B](t: in UnquotedTup[A, B]): String = ()


record Counter {
  var n: Int = 0
}

// Module-level `val` initializers exercise the zero-argument generic ctor
// extern from an init context the monomorphizer does not rewrite — the kept
// generic `newCD` must still resolve and construct a `ConcurrentDictionary<object,object>`.
val mapStr: CD[String, Counter] = newCD()

val mapInt: CD[Int, Counter] = newCD()

test "ctor + TryAdd + TryGetValue round-trips a record value (String key)" {
  val added = cdAdd(mapStr, "a", Counter(n = 7))
  assertTrue(added, "TryAdd of a fresh key succeeds")
  var got: Counter = default()
  val found = cdGet(mapStr, "a", got)
  assertTrue(found, "TryGetValue finds the added key")
  assertEqualInt(got.n, 7, "round-tripped value")
}

test "TryGetValue yields the shared reference; in-place mutation persists" {
  val _ = cdAdd(mapStr, "b", Counter(n = 0))
  var e: Counter = default()
  val f1 = cdGet(mapStr, "b", e)
  assertTrue(f1, "found b")
  e.n = e.n + 1
  // The dictionary value is a reference; mutating the fetched record mutates
  // the stored object, so a second lookup observes the increment (this is why
  // checkRateLimit / the circuit breaker need no explicit write-back).
  var e2: Counter = default()
  val f2 = cdGet(mapStr, "b", e2)
  assertTrue(f2, "found b again")
  assertEqualInt(e2.n, 1, "in-place mutation persisted (no write-back needed)")
}

test "set_Item write-back replaces the stored value" {
  val _ = cdAdd(mapStr, "c", Counter(n = 1))
  cdSet(mapStr, "c", Counter(n = 99))
  var got: Counter = default()
  val _ = cdGet(mapStr, "c", got)
  assertEqualInt(got.n, 99, "set_Item replaced the value")
}

test "non-zero-arg generic ctor: Tuple`2(T1, T2) constructs and round-trips (#3419)" {
  val t = newTup(1, "hi")
  assertEqual(tupToString(t), "(1, hi)", "Tuple(1, \"hi\").ToString()")
}

test "value-type key (Int) is boxed at the call boundary" {
  val _ = cdAdd(mapInt, 42, Counter(n = 5))
  var got: Counter = default()
  val found = cdGet(mapInt, 42, got)
  assertTrue(found, "Int key round-trips through the boxed `!0` position")
  assertEqualInt(got.n, 5, "value found via Int key")
  var miss: Counter = default()
  assertFalse(cdGet(mapInt, 99, miss), "absent Int key returns false")
}

test "Unquoted generic Tuple constructs and round-trips correctly" {
  val t = newUnquotedTup(2, "hello")
  assertEqual(unquotedTupToString(t), "(2, hello)", "UnquotedTuple(2, \"hello\").ToString()")
}

