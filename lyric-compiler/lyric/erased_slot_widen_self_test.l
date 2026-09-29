//! erased_slot_widen_self_test.l — #7782: a value stored into an erased
//! (`Object`) generic slot is boxed as the slot's declared element type, and
//! `Map.remove(k)` yields a `Bool`.
//!
//! On `--target jvm` a generic slot is an erased `java.lang.Object`: the
//! element of a `List[T]`/`Set[T]`/`Map[K, V]`, a generic record or union
//! field, a generic function parameter.  The checker lets an `Int` (an
//! unsuffixed literal or any `Int` expression) flow into a `Long` slot and a
//! `Byte` into an `Int` or `Long` slot, but the JVM backend boxed the value
//! by its own type: `xs.add(5)` on a `List[Long]` stored a
//! `java.lang.Integer`, and reading it back as a `Long` threw
//! `ClassCastException`.  A `Map[Long, V]` key boxed that way never compared
//! equal to the same value boxed as `java.lang.Long`, so lookups silently
//! missed.  The value is now widened and boxed as the slot's declared type.
//!
//! On `--target dotnet` generics are reified, but a `Set[T]` is an erased
//! `HashSet<object>`, and the concrete `List<T>`/`Dictionary<K, V>` methods
//! take the element type unboxed: an `Int` argument for a `Long` (or
//! `Double`) element was boxed as `Int32` (a `Set[Long]` lookup by a `Long`
//! missed, iterating it into a `Long` threw `InvalidCastException`) or
//! pushed as an `int32` where the method takes an `int64`/`float64`
//! (`InvalidProgramException`); `List.indexOf`/`lastIndexOf`/`remove(x)` were
//! not lowered at all.  Every element, key and value argument is now widened
//! to the slot's declared type before it is passed or boxed (#7785).  A
//! generic record's instantiation is inferred from its widest argument and
//! the narrower arguments are widened to it, whatever order they come in
//! (#7794).
//!
//! `m.remove(k)` is `Bool` (true iff the key was present) on every target;
//! the JVM backend lowered it as `Unit`, so any use of the result failed
//! stackmap simulation (J008).
//!
//! Run via native `lyric test` on both targets.  Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/erased_slot_widen_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/erased_slot_widen_self_test.l
@test_module
package Lyric.ErasedSlotWidenSelfTest

import Std.Core
import Std.Collections
import Std.Set
import Std.Testing

pub record Two[T] {
  a: T
  b: T
}

func pick[T](a: in T, b: in T, first: in Bool): T {
  if first {
    a
  } else {
    b
  }
}

func pushAll[T](xs: in List[T], x: in T): Unit {
  xs.add(x)
}

func orElse[T](o: in Option[T], d: in T): T {
  match o {
    case Some(v) -> v
    case None -> d
  }
}

func id[T](x: in T): T {
  x
}

func firstOf[T](xs: in List[T]): T {
  xs[0]
}

func sumLongs(xs: in List[Long]): Long {
  var total: Long = 0
  for v in xs {
    total = total + v
  }
  total
}

func sevenInt(): Int {
  7
}

func intFromCall(): Int {
  7
}

func longFromCall(): Long {
  3000000000
}

pub record Holder {
  n: Long
}

test "List[Long].add of an unsuffixed literal reads back as Long (#7782)" {
  val xs: List[Long] = newList()
  xs.add(5)
  xs.add(3000000000)
  val first: Long = xs[0]
  assertEqualLong(first + 1, 6, "xs[0] + 1")
  assertEqualLong(xs[1] - xs[0], 2999999995, "xs[1] - xs[0]")
  assertEqualLong(sumLongs(xs), 3000000005, "sum")
  assertEqualLong(firstOf(xs), 5, "generic read")
}

test "List[Long].add of an Int expression reads back as Long (#7782)" {
  val xs: List[Long] = newList()
  val n: Int = 40
  xs.add(n)
  xs.add(n + 2)
  xs.add(sevenInt())
  assertEqualLong(xs[0] * 2, 80, "n")
  assertEqualLong(xs[1], 42, "n + 2")
  assertEqualLong(xs[2] + 1, 8, "call result")
  assertEqualLong(sumLongs(xs), 89, "sum")
}

test "List[Long] index assignment and literal widen (#7782)" {
  val xs: List[Long] = [1, 2, 3]
  xs[1] = 20
  assertEqualLong(xs[0] + xs[1] + xs[2], 24, "sum after set")
  assertEqualLong(sumLongs(xs), 24, "for-loop sum")
}

test "List[Int].add of a Byte reads back as Int (#7782)" {
  val xs: List[Int] = newList()
  val b: Byte = 200.toByte()
  xs.add(b)
  assertEqualInt(xs[0] + 1, 201, "byte widened to Int")
}

test "Map[String, Long] values widen (#7782)" {
  val m: Map[String, Long] = newMap()
  m["a"] = 5
  m.add("b", 6)
  val n: Int = 7
  m["c"] = n
  val a: Long = m["a"]
  assertEqualLong(a + m["b"] + m["c"], 18, "index reads")
  var total: Long = 0
  for v in mapValues(m) {
    total = total + v
  }
  assertEqualLong(total, 18, "mapValues")
  match mapGet(m, "b") {
    case Some(v) -> assertEqualLong(v * 10, 60, "mapGet")
    case None -> assertTrue(false, "mapGet missed")
  }
}

test "Map[Long, String] keys widen (#7782)" {
  val m: Map[Long, String] = newMap()
  m[1] = "one"
  m.add(2, "two")
  val k: Long = 1
  assertEqual(m[k], "one", "Long key lookup")
  assertEqual(m[2], "two", "literal key lookup")
  assertTrue(m.containsKey(2), "containsKey literal")
  assertTrue(m.containsKey(k), "containsKey Long")
  match mapGet(m, 2) {
    case Some(v) -> assertEqual(v, "two", "mapGet literal key")
    case None -> assertTrue(false, "mapGet literal key missed")
  }
  var total: Long = 0
  for key in mapKeys(m) {
    total = total + key
  }
  assertEqualLong(total, 3, "mapKeys")
}

test "a generic record field pinned to Long widens its Int argument (#7782)" {
  val big: Long = 10
  val t = Two(a = big, b = 4)
  assertEqualLong(t.b + 1, 5, "literal")
  assertEqualLong(t.a + t.b, 14, "both fields")
  val n: Int = 11
  val u = Two(a = big, b = n)
  assertEqualLong(u.a + u.b, 21, "Int expr")
  val w = Two(a = 4, b = big)
  assertEqualLong(w.a + w.b, 14, "narrower argument first")
}

test "a generic function argument pinned to Long widens (#7782)" {
  val big: Long = 10
  val p: Long = pick(big, 3, false)
  assertEqualLong(p + 1, 4, "literal")
  val n: Int = 12
  assertEqualLong(pick(big, n, false) * 2, 24, "Int expr")
  val xs: List[Long] = newList()
  pushAll(xs, 6)
  pushAll(xs, n)
  assertEqualLong(xs[0] + xs[1], 18, "pushAll")
  val none: Option[Long] = None
  assertEqualLong(orElse(none, 7) + 1, 8, "orElse default")
  val w: Long = id(5)
  assertEqualLong(w + 1, 6, "id")
}

test "a record's arguments of two widths widen whatever their shape (#7790)" {
  val big: Long = 10
  val h = Holder(n = 40)
  // A call result after a narrower literal.
  val t2 = Two(a = 4, b = longFromCall())
  assertEqualLong(t2.a + t2.b, 3000000004, "literal, then call")
  // A binary operation and a field read as the wider argument.
  val t3 = Two(a = 5, b = big * 2)
  assertEqualLong(t3.a + t3.b, 25, "binary operation")
  val t4 = Two(a = h.n, b = 6)
  assertEqualLong(t4.a + t4.b, 46, "field read, then literal")
  // Both Int, one a call.
  val t5 = Two(a = sevenInt(), b = 8)
  assertEqualInt(t5.a + t5.b, 15, "Int call and literal")
  // An argument whose type cannot be known before it is lowered (a generic
  // call): the values are still stored widened, read through typed locals.
  val t6 = Two(a = 9, b = pick(big, 1, true))
  val a6: Long = t6.a
  val b6: Long = t6.b
  assertEqualLong(a6 + b6, 19, "generic call argument")
}

pub record LongBox {
  v: Long
}

func bigLong(): Long {
  3000000000
}

test "a record's wider call argument before a narrower literal (#7790, #7794)" {
  val t = Two(a = longFromCall(), b = 4)
  assertEqualLong(t.a + t.b, 3000000004, "call, then literal")
  val a1: Long = t.a
  assertEqualLong(a1, 3000000000, "wider value kept")
}

test "a record's Long argument keeps its value next to a narrower one, in either order (#7794)" {
  val big: Long = 1000000000
  val n: Int = 5
  val h = LongBox(v = bigLong())
  // A call result, either side of an Int literal or an Int expression.
  val c1 = Two(a = bigLong(), b = 4)
  assertEqualLong(c1.a, 3000000000, "call, then literal: a")
  assertEqualLong(c1.b, 4, "call, then literal: b")
  val c2 = Two(a = 4, b = bigLong())
  assertEqualLong(c2.a + c2.b, 3000000004, "literal, then call")
  val c3 = Two(a = bigLong(), b = n)
  assertEqualLong(c3.a + c3.b, 3000000005, "call, then Int expression")
  val c4 = Two(a = n, b = bigLong())
  assertEqualLong(c4.a + c4.b, 3000000005, "Int expression, then call")
  // A binary operation.
  val o1 = Two(a = big * 3, b = 4)
  assertEqualLong(o1.a + o1.b, 3000000004, "binary operation, then literal")
  val o2 = Two(a = 4, b = big * 3)
  assertEqualLong(o2.a + o2.b, 3000000004, "literal, then binary operation")
  val o3 = Two(a = big * 3, b = n + 1)
  assertEqualLong(o3.a + o3.b, 3000000006, "binary operation, then Int operation")
  // A field read.
  val f1 = Two(a = h.v, b = 4)
  assertEqualLong(f1.a + f1.b, 3000000004, "field read, then literal")
  val f2 = Two(a = 4, b = h.v)
  assertEqualLong(f2.a + f2.b, 3000000004, "literal, then field read")
  val f3 = Two(a = h.v, b = n)
  assertEqualLong(f3.a + f3.b, 3000000005, "field read, then Int expression")
  val f4 = Two(a = n, b = h.v)
  assertEqualLong(f4.a + f4.b, 3000000005, "Int expression, then field read")
  // A negative value must stay negative (sign-extended, not truncated).
  val neg = Two(a = 0 - bigLong(), b = 1)
  assertEqualLong(neg.a + neg.b, -2999999999, "negative wider argument")
}

test "a generic call's Long argument keeps its value next to a narrower one, in either order (#7794)" {
  val big: Long = 1000000000
  val n: Int = 5
  val h = LongBox(v = bigLong())
  assertEqualLong(pick(bigLong(), 4, true), 3000000000, "call, then literal")
  assertEqualLong(pick(4, bigLong(), false), 3000000000, "literal, then call")
  assertEqualLong(pick(big * 3, n, true), 3000000000, "binary operation, then Int expression")
  assertEqualLong(pick(n, big * 3, false), 3000000000, "Int expression, then binary operation")
  assertEqualLong(pick(h.v, 4, true), 3000000000, "field read, then literal")
  assertEqualLong(pick(4, h.v, false), 3000000000, "literal, then field read")
  assertEqualLong(pick(h.v, n, false), 5, "field read, then Int expression chosen")
}

test "a generic call's arguments of two widths widen whatever their shape (#7790)" {
  val big: Long = 10
  val h = Holder(n = 40)
  val p2: Long = pick(3, big * 2, false)
  assertEqualLong(p2, 20, "literal, then binary operation")
  val p3: Long = pick(h.n, 1, true)
  assertEqualLong(p3, 40, "field read, then literal")
  val p4: Long = pick(2, longFromCall(), false)
  assertEqualLong(p4 + 1, 3000000001, "literal, then call")
  val p5: Long = pick(2, longFromCall(), true)
  assertEqualLong(p5 + 1, 3, "narrower argument chosen")
}

test "Map.remove yields whether the key was present (#7782)" {
  val m: Map[String, Int] = newMap()
  m["a"] = 1
  m["b"] = 2
  val removed = m.remove("a")
  assertTrue(removed, "present key")
  val again = m.remove("a")
  assertFalse(again, "absent key")
  var hits = 0
  if m.remove("b") {
    hits = hits + 1
  }
  if m.remove("zzz") {
    hits = hits + 10
  }
  assertEqualInt(hits, 1, "if-condition form")
  assertEqualInt(mapSize(m), 0, "emptied")
}

test "Map.remove as a statement still removes (#7782)" {
  val m: Map[Long, String] = newMap()
  m[1] = "one"
  m[2] = "two"
  m.remove(1)
  m.remove(99)
  assertFalse(m.containsKey(1), "statement remove")
  assertTrue(m.containsKey(2), "other key kept")
  assertEqualInt(mapSize(m), 1, "size")
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

test "List[Long] remove and lastIndexOf take an Int argument as a Long element (#7785)" {
  val xs: List[Long] = newList()
  xs.add(5)
  xs.add(3000000000)
  xs.add(5)
  assertEqualInt(xs.lastIndexOf(5), 2, "lastIndexOf literal")
  val n: Int = 5
  assertEqualInt(xs.lastIndexOf(n), 2, "lastIndexOf Int expression")
  assertEqualInt(xs.indexOf(99), -1, "indexOf absent")
  assertTrue(xs.remove(n), "remove Int expression")
  assertEqualInt(xs.count, 2, "one removed")
  assertEqualLong(xs[0], 3000000000, "first match removed")
  assertTrue(xs.remove(3000000000), "remove Long literal")
  assertFalse(xs.remove(99), "remove absent")
  assertEqualInt(xs.count, 1, "size")
}

test "a Byte element of a Set[Int] or List[Int] is found by an Int value (#7785)" {
  val b: Byte = 200.toByte()
  val s: Set[Int] = newSet()
  s.add(b)
  assertTrue(s.contains(200), "Set contains")
  var total = 0
  for v in s {
    total = total + v
  }
  assertEqualInt(total, 200, "Set iterate")
  val xs: List[Int] = newList()
  xs.add(b)
  assertTrue(xs.contains(200), "List contains")
  assertEqualInt(xs.indexOf(200), 0, "List indexOf")
}

test "Map[Long, V] reads, removes and probes with an Int key (#7785)" {
  val m: Map[Long, Long] = newMap()
  val n: Int = 3
  m.add(n, n)
  m[4] = 3000000000
  val k3: Long = 3
  assertTrue(m.containsKey(k3), "Long key present")
  assertTrue(m.containsKey(n), "Int key present")
  assertEqualLong(m[n] + m[4], 3000000003, "Int-key reads")
  m[n] += 1
  assertEqualLong(m[k3], 4, "compound assignment through an Int key")
  match mapGet(m, n) {
    case Some(v) -> assertEqualLong(v, 4, "mapGet Int key")
    case None -> assertTrue(false, "mapGet Int key missed")
  }
  assertTrue(m.remove(n), "remove Int key")
  assertFalse(m.containsKey(k3), "removed")
}
