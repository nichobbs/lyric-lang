//! erased_slot_widen_jvm_self_test.l — the `--target jvm` half of #7782's
//! erased-slot widening that `--target dotnet` does not pass today.
//!
//! `lyric-compiler/lyric/erased_slot_widen_self_test.l` covers every shape
//! both targets agree on.  The shapes here fail on `--target dotnet`
//! for reasons in the MSIL backend, not in the JVM fix:
//!
//!   - a `Set[Long]` element added as an `Int` (`s.add(5)`) is stored boxed
//!     as `Int32`, so a lookup by a `Long` value misses (`s.contains(five)`
//!     with `five: Long` is false), and `setContains(s, 6)` (the generic
//!     `Std.Set` function, `T = Long`) misses too; iterating the set and
//!     adding each element to a `Long` fails with `InvalidCastException`;
//!   - `xs.contains(5)` and `xs.indexOf(3000000000)` on a `List[Long]`, and
//!     `List[Double].add(1)` and `Map[K, Double].add(k, n)` with an `Int`
//!     argument (the checker admits an `Int` argument to these extern
//!     collection methods) fail with `InvalidProgramException`.
//!
//! On `--target jvm` a value bound for an erased `Object` element, key or
//! value slot is widened and boxed as the slot's declared type, so these
//! store `java.lang.Long` / `java.lang.Double`.
//!
//!   lyric test --target jvm lyric-compiler/jvm/erased_slot_widen_jvm_self_test.l
@test_module
package Lyric.ErasedSlotWidenJvmSelfTest

import Std.Core
import Std.Collections
import Std.Set
import Std.Testing

pub record Holder {
  n: Long
}

func longFromCall(): Long {
  3000000000
}

func intFromCall(): Int {
  7
}

test "Set[Long] elements from calls, operations and field reads (#7790)" {
  val big: Long = 10
  val h = Holder(n = 40)
  val s: Set[Long] = newSet()
  setAdd(s, longFromCall())
  setAdd(s, h.n + 1)
  setAdd(s, intFromCall())
  assertTrue(setContains(s, big * 300000000), "call")
  assertTrue(setContains(s, 41), "field read plus literal")
  assertTrue(setContains(s, intFromCall()), "Int call")
  assertEqualInt(setSize(s), 3, "size")
}

test "Set[Long] membership with unsuffixed literals (#7782)" {
  val s: Set[Long] = newSet()
  s.add(5)
  s.add(5)
  val n: Int = 6
  s.add(n)
  assertEqualInt(setSize(s), 2, "dedup")
  assertTrue(s.contains(5), "contains literal")
  assertTrue(s.contains(6), "contains Int expr value")
  var total: Long = 0
  for v in s {
    total = total + v
  }
  assertEqualLong(total, 11, "iterate")
  assertTrue(s.remove(5), "remove literal")
  assertFalse(s.contains(5), "removed")
}

test "Set[Long] elements added as Int are found by a Long value (#7782)" {
  val s: Set[Long] = newSet()
  s.add(5)
  val n: Int = 6
  s.add(n)
  setAdd(s, 7)
  val five: Long = 5
  val six: Long = 6
  val seven: Long = 7
  assertTrue(s.contains(five), "added literal")
  assertTrue(s.contains(six), "added Int expression")
  assertTrue(setContains(s, seven), "added through setAdd")
  assertTrue(setContains(s, 6), "setContains with an Int literal")
  assertTrue(s.remove(five), "remove by Long")
  assertFalse(s.contains(5), "removed")
  assertEqualInt(setSize(s), 2, "size")
}

test "List[Long] lookups by an Int argument (#7782)" {
  val xs: List[Long] = newList()
  xs.add(5)
  xs.add(3000000000)
  assertTrue(xs.contains(5), "contains literal")
  val n: Int = 5
  assertTrue(xs.contains(n), "contains Int expression")
  assertEqualInt(xs.indexOf(3000000000), 1, "indexOf")
  assertEqualInt(xs.indexOf(n), 0, "indexOf Int expression")
}

test "List[Double] and Map[K, Double] store an Int argument as Double (#7782)" {
  val xs: List[Double] = newList()
  xs.add(1)
  val n: Int = 2
  xs.add(n)
  val d: Double = xs[0] + xs[1]
  assertTrue(d == 3.0, "list sum is 3.0")
  val m: Map[String, Double] = newMap()
  m["a"] = 4.0
  m.add("b", n)
  assertTrue(m["a"] + m["b"] == 6.0, "map sum is 6.0")
}
