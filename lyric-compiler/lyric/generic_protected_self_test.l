//! generic_protected_self_test.l — generic protected types (#7830).
//!
//! A protected type may declare type parameters (docs/01 §7.5):
//! `protected type Slot[T] { ... }`.  On `--target dotnet` it lowers to a
//! reified generic class (GenericParam rows, `!n` fields, TypeSpec-parented
//! member references), like a generic record (docs/43); on `--target jvm`
//! its type parameters erase to `Object`, like a generic record's, and reads
//! through an instantiation are cast back.  Construction is type-checked
//! like a record's: the type arguments are inferred from the field
//! arguments or taken from the expected type.
//!
//! Runs on both targets in CI (`lyric test` and `lyric test --target jvm`).
//! Concurrent exclusion and `when:` barriers on a generic protected type are
//! covered by `protected_exclusion_dotnet_self_test.l` /
//! `protected_exclusion_jvm_self_test.l`.
@test_module
package GenericProtectedSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Point {
  x: Int
  y: Int
}

protected type Cell[T] {
  var value: T
  var writes: Int = 0
  func get(): T {
    value
  }
  entry set(v: in T): Unit {
    value = v
    writes = writes + 1
  }
  func writeCount(): Int = writes
}

protected type Slot[T] {
  var item: Option[T] = None
  entry put(v: in T): Unit {
    item = Some(value = v)
  }
  entry take(): Option[T] {
    val taken = item
    item = None
    taken
  }
  func isFull(): Bool {
    match item {
      case Some(_) -> true
      case None -> false
    }
  }
}

protected type Registry[K, V] {
  var entries: Map[K, V]
  var log: List[K]
  entry store(k: in K, v: in V): Unit {
    entries[k] = v
    log.add(k)
  }
  func lookup(k: in K): Option[V] {
    mapGet(entries, k)
  }
  func size(): Int = entries.count
  func history(): List[K] = log
}

protected type Checked[T] {
  var value: T
  var version: Int = 0
  invariant: version >= 0
  entry replace(v: in T): Int {
    value = v
    version = version + 1
    version
  }
}

func newSlot[T](): Slot[T] {
  Slot()
}

func fillWith(s: in Slot[Point], p: in Point): Unit {
  s.put(p)
}

func cellOf[T](v: in T): Cell[T] {
  Cell(value = v)
}

test "a cell's type argument is inferred from its field argument" {
  val c = Cell(value = 1)
  c.set(41)
  assertEqualInt(c.get(), 41, "Int instantiation")
  assertEqualInt(c.writeCount(), 1, "entry ran once")
}

test "one generic protected type serves several instantiations" {
  val ints: Cell[Int] = Cell(value = 1)
  val strs: Cell[String] = Cell(value = "a")
  ints.set(2)
  strs.set("b")
  assertEqualInt(ints.get(), 2, "Int cell")
  assertEqual(strs.get(), "b", "String cell")
}

test "a record type argument round-trips through an entry" {
  val ps: Slot[Point] = newSlot()
  assertFalse(ps.isFull(), "starts empty")
  fillWith(ps, Point(x = 1, y = 2))
  assertTrue(ps.isFull(), "put fills it")
  match ps.take() {
    case Some(p) -> {
      assertEqualInt(p.x, 1, "x")
      assertEqualInt(p.y, 2, "y")
    }
    case None -> assertTrue(false, "take returned None after put")
  }
  assertFalse(ps.isFull(), "take empties it")
}

test "an Option[T] field defaults and is replaced by an entry" {
  val s: Slot[String] = Slot()
  s.put("hello")
  assertEqual(unwrapOr(s.take(), ""), "hello", "String payload")
  assertTrue(s.take().isNone, "second take is None")
}

test "two type parameters over collection fields" {
  val m: Map[String, Int] = newMap()
  val keys: List[String] = newList()
  val r: Registry[String, Int] = Registry(entries = m, log = keys)
  r.store("x", 10)
  r.store("y", 20)
  assertEqualInt(r.size(), 2, "two entries")
  assertEqualInt(unwrapOr(r.lookup("x"), -1), 10, "lookup x")
  assertTrue(r.lookup("z").isNone, "absent key")
  assertEqualInt(r.history().count, 2, "history")
  assertEqual(r.history()[1], "y", "history order")
}

test "a generic function returns a generic protected value" {
  val c = cellOf("seed")
  c.set("grown")
  assertEqual(c.get(), "grown", "String cell from a generic factory")
  val n = cellOf(7)
  n.set(8)
  assertEqualInt(n.get(), 8, "Int cell from the same factory")
}

test "a generic protected type keeps its invariant" {
  val c: Checked[String] = Checked(value = "v0")
  assertEqualInt(c.replace("v1"), 1, "first replace")
  assertEqualInt(c.replace("v2"), 2, "second replace")
}

record Holder {
  var item: Option[Int] = None
}

protected type IntBox {
  var item: Option[Int] = None
  entry fill(x: in Int): Unit {
    item = Some(value = x)
  }
  entry clear(): Unit {
    item = None
  }
  func empty(): Bool = item.isNone
}

// A `None` assigned to an `Option[Int]` field must be the field's own case
// class: MSIL used to build `Option_None<object>`, which `.isNone` (an
// `isinst Option_None<int>`) then read as not-None, so a `when: item.isNone`
// barrier never opened again.
test "a None assigned to an Option field reads as None" {
  val b = IntBox()
  b.fill(1)
  assertFalse(b.empty(), "filled")
  b.clear()
  assertTrue(b.empty(), "protected field cleared")
  var h = Holder()
  h.item = Some(value = 2)
  h.item = None
  assertTrue(h.item.isNone, "record field cleared")
  val s: Slot[Int] = Slot()
  s.put(5)
  val _ = s.take()
  assertFalse(s.isFull(), "generic protected field cleared")
}
