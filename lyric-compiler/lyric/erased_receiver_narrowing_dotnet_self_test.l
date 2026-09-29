//! erased_receiver_narrowing_dotnet_self_test.l — `--target dotnet` runtime
//! regression test for `Set[T]` receivers whose MSIL stack type is `object`
//! (#7755).  A `Set[T]` lowers to the legacy erased `HashSet<object>` storage,
//! whose parameters and locals are `object`; its `add` / `contains` / `remove` /
//! `count` members must narrow the receiver before the `callvirt` or the IL is
//! unverifiable.  The compiled output of this file is ilverified in CI by
//! `scripts/ilverify-selfhosted.sh`.
//!
//! The file is dotnet-only because `Std.Set` is unusable on the JVM (#7312);
//! the dual-target cases are in `erased_receiver_narrowing_self_test.l`.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/erased_receiver_narrowing_dotnet_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ErasedReceiverNarrowingDotnetSelfTest

import Std.Core
import Std.Collections
import Std.CollectionsHost
import Std.Set
import Std.Testing

func countOf(s: in Set[Int]): Int {
  s.count
}

test "Set[Int] through the Std.Set helpers" {
  val s: Set[Int] = newSet()
  setAdd(s, 4)
  setAdd(s, 5)
  setAdd(s, 4)
  assertEqualInt(setSize(s), 2, "duplicates collapse")
  assertTrue(setContains(s, 5), "contains a member")
  assertFalse(setContains(s, 6), "does not contain a non-member")
  assertTrue(setRemove(s, 4), "removes a member")
  assertEqualInt(setSize(s), 1, "one member left")
}

test "Set[Int] members on a local and a parameter" {
  val s: Set[Int] = newSet()
  s.add(1)
  s.add(2)
  s.add(3)
  assertEqualInt(s.count, 3, "count on a local")
  assertEqualInt(countOf(s), 3, "count through a parameter")
  assertTrue(s.contains(2), "contains on a local")
  assertTrue(s.remove(2), "remove on a local")
  assertFalse(s.contains(2), "removed member is gone")
}

test "Set[String] members" {
  val s: Set[String] = newSet()
  s.add("a")
  s.add("b")
  assertEqualInt(s.count, 2, "two strings")
  assertTrue(s.contains("a"), "contains a string member")
}
