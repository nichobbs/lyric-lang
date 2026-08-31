//! generic_extern_jvm_self_test.l — JVM analog of `generic_extern_self_test.l`
//! (#3432): regression test for `@externTarget` members whose declaring type
//! is a generic JDK type (`java.util.concurrent.ConcurrentHashMap`, etc.).
//!
//! Unlike MSIL — where a member of a generic BCL type needs a dedicated
//! closed-GENERICINST-TypeSpec emitter (`Msil.Codegen.emitGenericExternMember`,
//! #3392/#3413) because a member cannot be referenced through an open-generic
//! TypeRef (ECMA-335 §II.22.25) — the JVM has no reified generics at all:
//! every instantiation of `ConcurrentHashMap<K, V>` erases to the same raw
//! `java/util/concurrent/ConcurrentHashMap` class file, so ordinary auto-FFI
//! member resolution against the erased receiver class already produces the
//! correct `invokevirtual`/`invokeinterface` call.  The JVM-side gap #3432
//! actually tracked was narrower and is exercised here directly:
//!
//!  1. A GENERIC `extern type` alias (`JvmConcurrentDict[K, V] = "java.util.
//!     concurrent.ConcurrentHashMap"`) parses as `TGenericApp`, which used to
//!     erase to `Object` instead of resolving to its raw host class — auto-FFI
//!     then had no receiver class to resolve `.get`/`.put` against (#5458,
//!     fixed: `Jvm.Codegen.typeExprToJvmExtern`'s `TGenericApp` arm).
//!  2. A zero-argument `@externTarget(".....<init>")` constructor wrapper
//!     over that generic alias (the `newConcurrentDict[K, V]()` idiom used by
//!     `Resilience.Kernel.Jvm` / `Web.Kernel.Jvm` / `Jobs.Kernel.Jvm`) must
//!     construct the real erased class and have its declared parameter list
//!     verified against real JDK constructor metadata (F0015-J, ctor form —
//!     this file's own fix: `Jvm.Codegen.lowerExternTargetBody`'s `"<init>"`
//!     branch previously ran NO metadata verification at all, silently
//!     accepting a mistyped ctor signature that would only fail at runtime).
//!  3. Plain generic Lyric functions (no `@externTarget`) that call ordinary
//!     methods on a generic-extern-typed parameter (`cdTryGetValue`/`cdPut`,
//!     mirroring the ecosystem kernels) must monomorphize per call site and
//!     resolve those member calls against the erased receiver class.
//!
//! Run via native `lyric test --target jvm` (compiles the `@test_module` in
//! process through the self-hosted `Jvm.Bridge` `compileToJarBundled` and
//! runs it under `java`, asserting every runtime value).  Imports only
//! `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test --target jvm lyric-compiler/lyric/generic_extern_jvm_self_test.l
@test_module
package Lyric.GenericExternJvmSelfTest

import Std.Core
import Std.Testing

// Named `JvmDict` (not `CD`/`ConcurrentDict`) to avoid any accidental
// short-name collision with the MSIL sibling test's `CD` alias should both
// ever be linked into the same compilation unit.
extern type JvmDict[K, V] = "java.util.concurrent.ConcurrentHashMap"

@externTarget("java.util.concurrent.ConcurrentHashMap.<init>")
func newJvmDict[K, V](): JvmDict[K, V] = ()

// Plain generic Lyric functions over the generic extern-typed parameter —
// no per-member `@externTarget`: JVM auto-FFI resolves `.get`/`.put`/
// `.containsKey` against the erased `ConcurrentHashMap` receiver class
// directly once the monomorphizer specialises these to a concrete K/V pair.
func cdTryGetValue[K, V](dict: in JvmDict[K, V], key: in K, value: out V): Bool {
  value = dict.get(key)
  dict.containsKey(key)
}

func cdPut[K, V](dict: in JvmDict[K, V], key: in K, value: in V): Unit {
  val _ = dict.put(key, value)
}

record Counter {
  var n: Int = 0
}

// Module-level `val` initializer exercises the zero-argument generic ctor
// extern from an init context the monomorphizer does not walk as an ordinary
// call site — the explicit type application drives a concrete specialisation
// (mirrors `Web.Kernel.Jvm`'s `webRateLimitMap` idiom).
val mapStr: JvmDict[String, Counter] = newJvmDict[String, Counter]()

val mapInt: JvmDict[Int, Counter] = newJvmDict[Int, Counter]()

test "ctor + put/get round-trips a record value (String key)" {
  cdPut(mapStr, "a", Counter(n = 7))
  var got: Counter = default()
  val found = cdTryGetValue(mapStr, "a", got)
  assertTrue(found, "get finds the put key")
  assertEqualInt(got.n, 7, "round-tripped value")
}

test "get on an absent key returns false" {
  var miss: Counter = default()
  assertFalse(cdTryGetValue(mapStr, "does-not-exist", miss), "absent key returns false")
}

test "get yields the shared reference; in-place mutation persists" {
  cdPut(mapStr, "b", Counter(n = 0))
  var e: Counter = default()
  val f1 = cdTryGetValue(mapStr, "b", e)
  assertTrue(f1, "found b")
  e.n = e.n + 1
  // The map's value is a reference; mutating the fetched record mutates the
  // stored object, so a second lookup observes the increment — this is why
  // `checkRateLimit`'s tumbling-window state needs no explicit write-back.
  var e2: Counter = default()
  val f2 = cdTryGetValue(mapStr, "b", e2)
  assertTrue(f2, "found b again")
  assertEqualInt(e2.n, 1, "in-place mutation persisted (no write-back needed)")
}

test "put overwrites the stored value" {
  cdPut(mapStr, "c", Counter(n = 1))
  cdPut(mapStr, "c", Counter(n = 99))
  var got: Counter = default()
  val _ = cdTryGetValue(mapStr, "c", got)
  assertEqualInt(got.n, 99, "put replaced the value")
}

test "Int key round-trips through the erased Object-typed slot" {
  cdPut(mapInt, 42, Counter(n = 5))
  var got: Counter = default()
  val found = cdTryGetValue(mapInt, 42, got)
  assertTrue(found, "Int key round-trips")
  assertEqualInt(got.n, 5, "value found via Int key")
  var miss: Counter = default()
  assertFalse(cdTryGetValue(mapInt, 99, miss), "absent Int key returns false")
}
