//! closure_var_capture_self_test.l — dual-target runtime regression test for
//! by-reference closure capture of `var` locals (#7460).
//!
//! A `var` referenced inside a lambda is hoisted to a shared heap cell so the
//! closure and the enclosing scope read and write one location.  On
//! `--target dotnet` the cell for an un-annotated `var` was allocated before
//! its initializer was lowered, from the (absent) annotation: `var b = Box(...)`
//! built an `object[]` cell and then called `List<object>.Add` on it, so the
//! first field write through the captured record threw
//! `NullReferenceException`.  The cell is now built from the initializer's
//! final type, matching every cell read/write site.
//!
//! Each case asserts runtime values on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/closure_var_capture_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/closure_var_capture_self_test.l
@test_module
package Lyric.ClosureVarCaptureSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Box {
  var n: Int
  var label: String
}

func run(f: in () -> Unit): Unit {
  f()
}

func readInt(f: in () -> Int): Int {
  f()
}

// ── Records ─────────────────────────────────────────────────────────────────
test "var record: field write inside closure is visible after (#7460)" {
  var b = Box(n = 1, label = "a")
  run({ -> b.n = 5 })
  assertEqualInt(b.n, 5, "b.n after closure write")
}

test "val record: field write inside closure is visible after" {
  val c = Box(n = 1, label = "a")
  run({ -> c.n = 7 })
  assertEqualInt(c.n, 7, "c.n after closure write")
}

test "annotated var record: field write inside closure is visible after" {
  var b: Box = Box(n = 1, label = "a")
  run({ -> b.n = 11 })
  assertEqualInt(b.n, 11, "annotated b.n after closure write")
}

test "var record: reassigning the whole var inside closure" {
  var b = Box(n = 1, label = "a")
  run({ -> b = Box(n = 20, label = "z") })
  assertEqualInt(b.n, 20, "b.n after closure reassignment")
  assertEqual(b.label, "z", "b.label after closure reassignment")
}

test "var record: copy-and-reassign inside closure" {
  var b = Box(n = 1, label = "a")
  run({ -> b = b.copy(n = b.n + 41) })
  assertEqualInt(b.n, 42, "b.n after closure copy")
  assertEqual(b.label, "a", "b.label preserved by copy")
}

test "var record: compound field assignment inside closure" {
  var b = Box(n = 1, label = "a")
  run({ -> b.n += 1; b.n *= 10; b.label += "bc" })
  assertEqualInt(b.n, 20, "b.n after compound writes")
  assertEqual(b.label, "abc", "b.label after String +=")
}

test "var record: mutation outside after closure creation is seen inside" {
  var b = Box(n = 1, label = "a")
  val get = { -> b.n }
  b.n = 3
  assertEqualInt(readInt(get), 3, "closure sees outer field write")
  b = Box(n = 9, label = "q")
  assertEqualInt(readInt(get), 9, "closure sees outer reassignment")
}

test "var record: field read inside closure after closure field write" {
  var b = Box(n = 1, label = "a")
  val bump = { -> b.n = b.n + 1 }
  val get = { -> b.n }
  bump()
  bump()
  assertEqualInt(readInt(get), 3, "second closure sees first closure's writes")
  assertEqualInt(b.n, 3, "enclosing scope sees closure writes")
}

test "var record: nested closures mutate a field two levels down" {
  var b = Box(n = 1, label = "a")
  run({ -> run({ -> b.n = b.n + 100 }); b.n += 1 })
  assertEqualInt(b.n, 102, "b.n after nested closure writes")
}

test "var record: nested closure reassigns the whole var" {
  var b = Box(n = 1, label = "a")
  run({ -> run({ -> b = Box(n = 55, label = "inner") }) })
  assertEqualInt(b.n, 55, "b.n after nested reassignment")
  assertEqual(b.label, "inner", "b.label after nested reassignment")
}

// ── Primitives and String ───────────────────────────────────────────────────
test "var Int: reassignment and compound assignment inside closure" {
  var i = 1
  run({ -> i = i + 4; i *= 3 })
  assertEqualInt(i, 15, "i after closure writes")
  i = 2
  assertEqualInt(readInt({ -> i }), 2, "closure sees outer write")
}

test "var Long: compound assignment inside closure" {
  var l = 5i64
  run({ -> l += 10i64 })
  assertTrue(l == 15i64, "l after closure +=")
}

test "var String: reassignment and += inside closure" {
  var s = "x"
  run({ -> s = s + "y"; s += "z" })
  assertEqual(s, "xyz", "s after closure writes")
  s = "outer"
  var seen = ""
  run({ -> seen = s })
  assertEqual(seen, "outer", "closure sees outer String write")
}

test "var without initializer: assigned inside closure, read after" {
  var i: Int
  var s: String
  var b: Box
  run({ -> i = 4; s = "q"; b = Box(n = 3, label = "late") })
  assertEqualInt(i, 4, "i assigned in closure")
  assertEqual(s, "q", "s assigned in closure")
  assertEqualInt(b.n, 3, "b assigned in closure")
}

// ── Slices and collections ──────────────────────────────────────────────────
test "var slice[Int]: element write inside closure" {
  var xs = [1, 2, 3]
  run({ -> xs[0] = 9; xs[2] += 10 })
  assertEqualInt(xs[0], 9, "xs[0] after closure element write")
  assertEqualInt(xs[2], 13, "xs[2] after closure element +=")
}

test "annotated var slice[Int]: reassignment inside closure" {
  var xs: slice[Int] = [1, 2, 3]
  run({ -> xs = xs.append(4) })
  assertEqualInt(xs.length.toInt(), 4, "xs.length after closure append")
  assertEqualInt(xs[3], 4, "xs[3] after closure append")
}

test "var slice[record]: element field write and append inside closure" {
  var boxes: slice[Box] = [Box(n = 1, label = "a")]
  run({ -> boxes[0].n = 8; boxes = boxes.append(Box(n = 2, label = "b")) })
  assertEqualInt(boxes.length.toInt(), 2, "boxes.length after closure append")
  assertEqualInt(boxes[0].n, 8, "boxes[0].n after closure field write")
  assertEqualInt(boxes[1].n, 2, "boxes[1].n after closure append")
}

test "var List[Int]: add and reassignment inside closure" {
  var xs: List[Int] = newList()
  run({ -> xs.add(1); xs.add(2) })
  assertEqualInt(xs.count, 2, "xs.count after closure adds")
  run({ -> val fresh: List[Int] = newList(); fresh.add(7); xs = fresh })
  assertEqualInt(xs.count, 1, "xs.count after closure reassignment")
  assertEqualInt(xs[0], 7, "xs[0] after closure reassignment")
}
