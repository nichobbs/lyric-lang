//! stdlib_parity_self_test.l — cross-target parity regression test for stdlib
//! and builtin behaviour that used to differ between `--target dotnet` and
//! `--target jvm` (#7301, #7312, #8314, #7893, #7912).  Every assertion holds
//! on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/stdlib_parity_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/stdlib_parity_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.StdlibParitySelfTest

import Std.Core
import Std.Collections
import Std.Set
import Std.Time
import Std.Testing

test "Map.add on an existing key replaces the value (#7301)" {
  val m: Map[String, String] = newMap()
  m.add("k", "a")
  m.add("k", "b")
  assertEqualInt(m.count, 1, "one entry")
  assertEqual(unwrapOr(mapGet(m, "k"), "?"), "b", "the last add wins")
}

test "Map.add replaces through an erased receiver (#7301)" {
  val m: Map[Int, List[Int]] = newMap()
  val first: List[Int] = newList()
  first.add(1)
  val second: List[Int] = newList()
  second.add(2)
  m.add(7, first)
  m.add(7, second)
  assertEqualInt(m.count, 1, "one entry")
  assertEqualInt(unwrapOr(mapGet(m, 7), first)[0], 2, "the second list replaced the first")
}

test "Std.Set works on every target (#7312)" {
  val s: Set[Int] = newSet()
  setAdd(s, 1)
  setAdd(s, 2)
  setAdd(s, 2)
  assertEqualInt(setSize(s), 2, "duplicates are dropped")
  assertTrue(setContains(s, 2), "membership")
  assertFalse(setContains(s, 3), "non-membership")
  val xs: slice[Int] = [2, 3, 4]
  val t = setFromSlice(xs)
  assertEqualInt(setSize(setUnion(s, t)), 4, "union")
  assertEqualInt(setSize(setIntersection(s, t)), 1, "intersect")
  assertEqualInt(setSize(setDifference(s, t)), 1, "difference")
}

type Age = Int range 0 ..= 150

func Age.toString(self: in Age): String = "age:" + toString(self.value)

type Id = Long

test "a user toString on a distinct type wins over the builtin arm (#7354)" {
  val a = Age.from(30)
  assertEqual(a.toString(), "age:30", "method call on a range subtype")
  assertEqual(toString(a), "30", "the builtin renders the underlying value")
  assertEqual("${a}", "30", "interpolation renders the underlying value")
  val i = Id.from(5i64)
  assertEqual(i.toString(), "5", "no user method: the underlying value")
}

test "print takes any value and println takes none (#7893, #7912)" {
  print(42)
  print(true)
  print(1.5)
  print("\n")
  println()
  println(7)
  assertTrue(true, "reached")
}

record Holder {
  xs: List[Int]
}

func intList(a: in Int, b: in Int): List[Int] {
  val xs: List[Int] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

test "== on tuples compares the elements (#8169)" {
  assertTrue((1, 2) == (1, 2), "two Int tuples")
  assertFalse((1, 2) == (1, 3), "different element")
  assertTrue((1, "a") != (1, "b"), "different String element")
  val a = (7, "x", true)
  val b = (7, "x", true)
  assertTrue(a == b, "separately built tuples")
  assertFalse(a != b, "!= on equal tuples")
}

test "== on Lists compares the elements in order (#8169)" {
  assertTrue(intList(1, 2) == intList(1, 2), "equal lists")
  assertFalse(intList(1, 2) == intList(2, 1), "order matters")
  assertTrue(intList(1, 2) != intList(1, 3), "different element")
  val short: List[Int] = newList()
  short.add(1)
  assertFalse(short == intList(1, 2), "different length")
  val e1: List[Int] = newList()
  val e2: List[Int] = newList()
  assertTrue(e1 == e2, "two empty lists")
  val nested1: List[List[Int]] = newList()
  nested1.add(intList(1, 2))
  val nested2: List[List[Int]] = newList()
  nested2.add(intList(1, 2))
  assertTrue(nested1 == nested2, "nested lists")
  val s1: List[String] = newList()
  s1.add("a")
  val s2: List[String] = newList()
  s2.add("a")
  assertTrue(s1 == s2, "String elements by value")
}

test "== on a record holding a List agrees with its collection key (#8169)" {
  val h1 = Holder(xs = intList(1, 2))
  val h2 = Holder(xs = intList(1, 2))
  assertTrue(h1 == h2, "equal Lists in equal records")
  assertFalse(h1 == Holder(xs = intList(2, 1)), "different Lists")
  val m: Map[Holder, Int] = newMap()
  m.add(h1, 1)
  assertTrue(m.containsKey(h2), "the same relation as a Map key")
}

test "== on Maps and Sets compares the contents (#8169)" {
  val m1: Map[String, Int] = newMap()
  m1.add("a", 1)
  m1.add("b", 2)
  val m2: Map[String, Int] = newMap()
  m2.add("b", 2)
  m2.add("a", 1)
  assertTrue(m1 == m2, "maps ignore insertion order")
  m2.add("a", 9)
  assertTrue(m1 != m2, "a different value")
  val m3: Map[String, Int] = newMap()
  m3.add("a", 1)
  assertTrue(m1 != m3, "a different size")
  val s1: Set[Int] = newSet()
  s1.add(1)
  s1.add(2)
  val s2: Set[Int] = newSet()
  s2.add(2)
  s2.add(1)
  assertTrue(s1 == s2, "sets ignore insertion order")
  s2.add(3)
  assertTrue(s1 != s2, "a different member")
  val ml1: Map[String, List[Int]] = newMap()
  ml1.add("k", intList(1, 2))
  val ml2: Map[String, List[Int]] = newMap()
  ml2.add("k", intList(1, 2))
  assertTrue(ml1 == ml2, "List values compare by element")
}

async func collectionEqInAsync(): Int {
  val m1: Map[String, Int] = newMap()
  m1.add("k", 1)
  val m2: Map[String, Int] = newMap()
  m2.add("k", 1)
  val s1: Set[Int] = newSet()
  s1.add(4)
  val s2: Set[Int] = newSet()
  s2.add(4)
  var n = 0
  if intList(1, 2) == intList(1, 2) {
    n = n + 1
  }
  if m1 == m2 {
    n = n + 10
  }
  if s1 == s2 {
    n = n + 100
  }
  if (1, "a") == (1, "a") {
    n = n + 1000
  }
  n
}

test "== on collections inside an async function (#8169)" {
  assertEqualInt(await collectionEqInAsync(), 1111, "list, map, set and tuple")
}

func isoOf(text: in String): String {
  match parseOptInstant(text) {
    case Some(t) -> toIsoString(t)
    case None -> "unparsed"
  }
}

test "toIsoString omits a zero fraction (#8314)" {
  assertEqual(toIsoString(fromEpochMillis(5000i64)), "1970-01-01T00:00:05Z", "whole seconds")
  assertEqual(toIsoString(fromEpochMillis(0i64)), "1970-01-01T00:00:00Z", "the epoch")
}

test "toIsoString prints the shortest of 3, 6 or 9 fraction digits (#8314)" {
  assertEqual(toIsoString(fromEpochMillis(5500i64)), "1970-01-01T00:00:05.500Z", "milliseconds")
  assertEqual(toIsoString(fromEpochMillis(5001i64)), "1970-01-01T00:00:05.001Z", "one millisecond")
  assertEqual(isoOf("2024-12-31T23:59:59.000001Z"), "2024-12-31T23:59:59.000001Z", "microseconds")
  assertEqual(isoOf("2024-12-31T23:59:59.1234567Z"), "2024-12-31T23:59:59.123456700Z", "100 ns ticks")
  assertEqual(isoOf("2024-12-31T23:59:59.5Z"), "2024-12-31T23:59:59.500Z", "a short fraction")
}

func nanD(z: in Double): Double = z / z

func doubles(a: in Double, b: in Double): List[Double] {
  val xs: List[Double] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

test "== on a List[Double] follows D172 (#8439)" {
  assertTrue(doubles(0.0, 1.5) == doubles(-0.0, 1.5), "zero equals negative zero")
  assertFalse(doubles(0.0, 1.5) != doubles(-0.0, 1.5), "!= agrees")
  assertTrue(doubles(nanD(0.0), 1.0) == doubles(nanD(0.0), 1.0), "NaN equals NaN")
  assertFalse(doubles(0.0, 1.5) == doubles(0.0, 2.5), "a different element")
  assertFalse(doubles(0.0, 1.5) == doubles(0.0, nanD(0.0)), "a number is not NaN")
}

test "== on a Set[Double] and a Map with Double values follows D172 (#8439)" {
  val s1: Set[Double] = newSet()
  setAdd(s1, 0.0)
  setAdd(s1, 2.0)
  val s2: Set[Double] = newSet()
  setAdd(s2, 2.0)
  setAdd(s2, -0.0)
  assertTrue(s1 == s2, "a set holds zero and negative zero alike")
  val s3: Set[Double] = newSet()
  setAdd(s3, 2.0)
  setAdd(s3, 3.0)
  assertFalse(s1 == s3, "a different member")
  val m1: Map[String, Double] = newMap()
  m1.add("a", 0.0)
  val m2: Map[String, Double] = newMap()
  m2.add("a", -0.0)
  assertTrue(m1 == m2, "a map value")
  val m3: Map[String, Double] = newMap()
  m3.add("a", nanD(0.0))
  val m4: Map[String, Double] = newMap()
  m4.add("a", nanD(0.0))
  assertTrue(m3 == m4, "a NaN map value")
  assertFalse(m1 == m3, "a different map value")
  val m5: Map[String, Double] = newMap()
  m5.add("b", 0.0)
  assertFalse(m1 == m5, "a different key")
}

test "a Set[Double] holding both zeros is not equal to one holding a single zero (#8439)" {
  val both: Set[Double] = newSet()
  setAdd(both, 0.0)
  setAdd(both, -0.0)
  val one: Set[Double] = newSet()
  setAdd(one, 0.0)
  setAdd(one, 1.0)
  assertFalse(both == one, "two members cannot share one match")
  assertFalse(one == both, "and the other way round")
}

test "== on a Map with Double keys and on nested Lists follows D172 (#8439)" {
  val k1: Map[Double, Int] = newMap()
  k1.add(0.0, 1)
  val k2: Map[Double, Int] = newMap()
  k2.add(-0.0, 1)
  assertTrue(k1 == k2, "a key found by the scan")
  val k3: Map[Double, Int] = newMap()
  k3.add(-0.0, 2)
  assertFalse(k1 == k3, "the value at the matched key differs")
  val outer1: List[List[Double]] = newList()
  outer1.add(doubles(0.0, 1.0))
  val outer2: List[List[Double]] = newList()
  outer2.add(doubles(-0.0, 1.0))
  assertTrue(outer1 == outer2, "a nested list")
}
