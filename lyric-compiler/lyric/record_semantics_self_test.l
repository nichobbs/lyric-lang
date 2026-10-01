//! Record value and reference semantics (D157).
//!
//! A record with no `var` field is a value: it cannot be mutated, so whether a
//! backend copies or shares its storage is unobservable, and `.copy(...)` is
//! the way to derive a changed value.  A record with a `var` field has
//! identity: assignment, argument passing, returning, and storing in a field
//! or collection all share one instance, and a write through any binding
//! (including an `in` parameter) is seen through every other.  `.copy()` on a
//! mutable record makes a new, independent instance.
//!
//! These cases pin that behaviour identically on every backend, so a backend
//! that starts copying mutable records (or sharing a `.copy()` result) fails
//! here rather than silently changing program meaning.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/record_semantics_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/record_semantics_self_test.l
//!   lyric test --target native lyric-compiler/lyric/record_semantics_self_test.l
@test_module
package Lyric.RecordSemanticsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Point {
  x: Int
  y: Int
}

record Counter {
  var n: Int
  label: String
}

record Cell {
  var v: Int
}

record Holder {
  var cell: Cell
  tag: String
}

func identity(c: in Counter): Counter = c

func bump(c: in Counter) {
  c.n = c.n + 1
}

func movedRight(p: in Point): Point = p.copy(x = p.x + 1)

test "an immutable record is unchanged by deriving a new value from it" {
  val p = Point(x = 1, y = 2)
  val q = movedRight(p)
  assertEqualInt(p.x, 1, "original x")
  assertEqualInt(q.x, 2, "derived x")
  assertEqualInt(q.y, 2, "derived y keeps the original")
}

test "assigning a mutable record shares the instance" {
  var a = Counter(n = 1, label = "a")
  var b = a
  b.n = 10
  assertEqualInt(a.n, 10, "write through the second binding is seen through the first")
}

test "a mutable record returned from a function is the same instance" {
  var a = Counter(n = 1, label = "a")
  var b = identity(a)
  b.n = 20
  assertEqualInt(a.n, 20, "write through the returned binding is seen by the caller")
}

test "a callee writes a mutable record through an in parameter" {
  val a = Counter(n = 1, label = "a")
  bump(a)
  bump(a)
  assertEqualInt(a.n, 3, "both writes are seen by the caller")
}

test "a mutable record stored in a list is shared with the list" {
  var a = Counter(n = 1, label = "a")
  val xs: List[Counter] = newList()
  xs.add(a)
  a.n = 30
  assertEqualInt(xs[0].n, 30, "a later write through the source is seen in the list")
  var b = xs[0]
  b.n = 31
  assertEqualInt(a.n, 31, "a write through an element read is seen through the source")
}

test "a mutable record held in a field is shared with the holder" {
  var h = Holder(cell = Cell(v = 1), tag = "h")
  var c = h.cell
  c.v = 40
  assertEqualInt(h.cell.v, 40, "write through the extracted field is seen through the holder")
  var h2 = h
  h2.cell = Cell(v = 41)
  assertEqualInt(h.cell.v, 41, "replacing a var field through a shared holder is seen by both")
}

test "copy on a mutable record makes an independent instance" {
  var a = Counter(n = 1, label = "a")
  var b = a.copy()
  b.n = 50
  assertEqualInt(a.n, 1, "the original is unchanged")
  assertEqualInt(b.n, 50, "the copy holds its own write")
  var c = a.copy(n = 7)
  c.n = 8
  assertEqualInt(a.n, 1, "a copy with an override is independent too")
}
