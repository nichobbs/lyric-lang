//! record_copy_self_test.l — runtime tests for record `.copy(field = value)`
//! (docs/01-language-reference.md §2.4): a non-destructive update producing a
//! new record with the named fields replaced and every other field copied.
//!
//! The type checker validates each call (named arguments only, real fields,
//! assignable values; T0127/T0101/T0104) and `Lyric.Mono` rewrites it into a
//! full constructor call that evaluates the receiver and each argument once,
//! left to right.  Runs on both targets:
//!   lyric test lyric-compiler/lyric/record_copy_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/record_copy_self_test.l
@test_module
package RecordCopySelfTest

import Std.Core
import Std.Testing

record Point {
  x: Int
  y: Int
}

record Customer {
  name: String
  limit: Long
  tags: List[String]
  note: Option[String]
}

record Box[T] {
  value: T
  label: String
}

record Counter {
  hits: List[Int]
}

func tick(c: in Counter, n: in Int): Int {
  c.hits.add(n)
  return n
}

func moved(p: in Point, dx: in Int): Point {
  return p.copy(x = p.x + dx)
}

test "copy replaces the named field and keeps the rest" {
  val p = Point(x = 1, y = 2)
  val q = p.copy(x = 10)
  assertEqualInt(q.x, 10, "x replaced")
  assertEqualInt(q.y, 2, "y kept")
  assertEqualInt(p.x, 1, "original unchanged")
}

test "copy with several fields in any order" {
  val c = Customer(name = "Acme", limit = 5000, tags = newList(), note = None)
  val d = c.copy(note = Some(value = "vip"), limit = 9000)
  assertEqual(d.name, "Acme", "name kept")
  assertTrue(d.limit == 9000, "limit replaced")
  match d.note {
    case Some(n) -> assertEqual(n, "vip", "note replaced")
    case None -> assertTrue(false, "expected a note")
  }
}

test "copy with no arguments is a shallow copy" {
  val c = Customer(name = "Acme", limit = 1, tags = newList(), note = None)
  val d = c.copy()
  assertEqual(d.name, "Acme", "name")
  d.tags.add("shared")
  assertEqualInt(c.tags.count, 1, "fields are shared, not deep-copied")
}

test "copy of a generic record keeps its instantiation" {
  val b = Box(value = 41, label = "answer")
  val c = b.copy(value = b.value + 1)
  assertEqualInt(c.value, 42, "value replaced")
  assertEqual(c.label, "answer", "label kept")
}

test "copy in return position and as an argument" {
  val p = moved(Point(x = 1, y = 1), 4)
  assertEqualInt(p.x, 5, "moved")
  assertEqualInt(moved(p.copy(y = 7), 1).y, 7, "nested copy")
}

test "receiver and arguments are evaluated once, left to right" {
  val log = Counter(hits = newList())
  val p = Point(x = 0, y = 0)
  val q = p.copy(y = tick(log, 2), x = tick(log, 1))
  assertEqualInt(q.x, 1, "x")
  assertEqualInt(q.y, 2, "y")
  assertEqualInt(log.hits.count, 2, "each argument evaluated once")
  assertEqualInt(log.hits[0], 2, "source order: y first")
  assertEqualInt(log.hits[1], 1, "then x")
}

test "copy chains" {
  val p = Point(x = 1, y = 1).copy(x = 2).copy(y = 3)
  assertEqualInt(p.x + p.y, 5, "chained copies")
}

func noteText(c: in Customer): String {
  match c.note {
    case Some(s) -> "note " + s
    case None -> "no note"
  }
}

// A bare `None` or `newList()` argument is built at the field's type: the
// argument's temporary is annotated with it. On MSIL an unannotated `None`
// was `Option<object>`, so a later `match` on the field was not exhaustive.
test "copy with a bare None or empty list argument keeps the field's type" {
  val tags: List[String] = newList()
  tags.add("vip")
  val c = Customer(name = "Ada", limit = 10i64, tags = tags, note = Some(value = "x"))
  val cleared = c.copy(note = None, tags = newList())
  assertEqual(noteText(cleared), "no note", "copy(note = None) matches the None arm")
  assertEqualInt(cleared.tags.count, 0, "copy(tags = newList()) is an empty list")
  cleared.tags.add("new")
  assertEqual(cleared.tags[0], "new", "the copied empty list holds strings")
  assertEqual(noteText(cleared.copy(note = Some(value = "y"))), "note y", "copy(note = Some(..)) matches the Some arm")
}
