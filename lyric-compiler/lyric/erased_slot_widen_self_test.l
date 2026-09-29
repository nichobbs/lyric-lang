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
//! `Set[Long]`, `List[Long]` lookup and `List[Double]` shapes that `--target dotnet` does not yet
//! pass are in `lyric-compiler/jvm/erased_slot_widen_jvm_self_test.l`.
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
