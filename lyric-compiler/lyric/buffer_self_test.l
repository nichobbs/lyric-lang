//! `buffer[T]` (D185, docs/67 §4.4): a contiguous, runtime-length sequence of
//! `Plain` elements with value semantics, the same behaviour on every target.
//!
//! Construction, indexing, element writes through a `var` local, a `var`
//! field and an `inout` parameter, copies on assignment, passing and
//! returning (a write through one binding is never seen through another),
//! `.length`, `for x in b`, the `Std.Buffer` functions, and the bounds panic.
//! A buffer nested with an array (a buffer of arrays, an array of buffers)
//! copies on the first write to either level (D226, #8521).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/buffer_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/buffer_self_test.l
//!   lyric test --target native lyric-compiler/lyric/buffer_self_test.l
@test_module
package Lyric.BufferSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Buffer
import Std.Bench

record Vec3 {
  x: Float
  y: Float
  z: Float
}

ref record Mesh {
  var verts: buffer[Vec3]
  var label: String
}

func sumOf(b: in buffer[Int]): Int {
  var t = 0
  for x in b {
    t = t + x
  }
  t
}

func bump(b: inout buffer[Int], i: in Int) {
  b[i] = b[i] + 10
}

func keep(b: in buffer[Int]): buffer[Int] {
  var c = b
  c[0] = 99
  c
}

func firstSquared(n: in Int): buffer[Int] {
  var b = filled(n, 0)
  var i = 0
  while i < n {
    b[i] = i * i
    i = i + 1
  }
  b
}

test "filled builds a buffer and elements read back" {
  val b = filled(4, 7)
  assertEqualInt(b.length, 4, "length")
  assertEqualInt(b[0], 7, "first")
  assertEqualInt(b[3], 7, "last")
  val f = filled(2, 1.5f32)
  assertTrue(f[1] == 1.5f32, "Float element")
  val flags = filled(2, true)
  assertTrue(flags[0] and flags[1], "Bool elements")
}

test "elements are written through a var local, a var field and an inout parameter" {
  var b = filled(4, 0)
  b[1] = 20
  b[2] += 5
  assertEqualInt(b[1], 20, "assigned")
  assertEqualInt(b[2], 5, "compound assigned")
  bump(b, 3)
  assertEqualInt(b[3], 10, "inout")
  var src = filled(2, Vec3(x = 0.0, y = 0.0, z = 0.0))
  val mesh = Mesh(verts = src, label = "m")
  src[1] = Vec3(x = 1.0, y = 2.0, z = 3.0)
  assertTrue(src[1].y == 2.0f32, "the variable's element")
  assertTrue(mesh.verts[1].y == 0.0f32, "a record built from the buffer holds its own copy")
  var held = Mesh(verts = filled(2, Vec3(x = 0.0, y = 0.0, z = 0.0)), label = "h")
  held.verts[1] = Vec3(x = 4.0, y = 5.0, z = 6.0)
  assertTrue(held.verts[1].y == 5.0f32, "a var field's element")
}

test "assigning a buffer copies it" {
  var a = filled(3, 1)
  var b = a
  b[0] = 50
  assertEqualInt(a[0], 1, "a is untouched")
  assertEqualInt(b[0], 50, "b changed")
  a[1] = 7
  assertEqualInt(b[1], 1, "b is untouched by a write to a")
}

test "passing and returning a buffer copies it" {
  val a = filled(4, 2)
  val k = keep(a)
  assertEqualInt(a[0], 2, "the argument is untouched")
  assertEqualInt(k[0], 99, "the result changed")
  var w = filled(4, 3)
  val snapshot = w
  w[0] = 0
  assertEqualInt(snapshot[0], 3, "a val taken before a write is a snapshot")
  assertEqualInt(sumOf(snapshot), 12, "sum of the snapshot")
}

test "a closure over a copy sees the buffer as it was copied" {
  var b = filled(2, 1)
  val snapshot = b
  val read = { -> snapshot[0] }
  b[0] = 9
  assertEqualInt(read(), 1, "the closure saw the copy")
  assertEqualInt(b[0], 9, "the variable changed")
}

test "for iterates the buffer's value when the loop starts" {
  var b = firstSquared(5)
  var t = 0
  for x in b {
    b[0] = 1000
    t = t + x
  }
  assertEqualInt(t, 0 + 1 + 4 + 9 + 16, "sum of squares")
  assertEqualInt(b[0], 1000, "the write inside the loop landed")
}

test "length is the length it was created with" {
  assertEqualInt(filled(0, 0).length, 0, "empty")
  assertEqualInt(firstSquared(6).length, 6, "six")
}

test "fromSlice copies, view and toSlice copy back" {
  val s: slice[Int] = [4, 5, 6, 7]
  var b = fromSlice(s)
  assertEqualInt(b.length, 4, "length")
  b[0] = 0
  assertEqualInt(s[0], 4, "the slice is untouched")
  val v = view(b, 1, 3)
  assertEqualInt(v.length, 2, "view length")
  assertEqualInt(v[0], 5, "view first")
  b[1] = 500
  assertEqualInt(v[0], 5, "a later write is not seen through the view")
  assertEqualInt(toSlice(b)[1], 500, "toSlice reads the current value")
}

test "grow and truncate return new buffers" {
  val b = firstSquared(3)
  val g = grow(b, 5, -1)
  assertEqualInt(g.length, 5, "grown length")
  assertEqualInt(g[2], 4, "kept element")
  assertEqualInt(g[4], -1, "filled element")
  assertEqualInt(b.length, 3, "the original is unchanged")
  val t = truncate(g, 2)
  assertEqualInt(t.length, 2, "truncated length")
  assertEqualInt(t[1], 1, "kept after truncate")
}

test "a buffer of records" {
  var vs = filled(3, Vec3(x = 0.0, y = 0.0, z = 0.0))
  vs[2] = vs[2].copy(z = 4.0)
  assertTrue(vs[2].z == 4.0f32, "copy then store")
  assertTrue(vs[0].z == 0.0f32, "others untouched")
}

// ── Sharing and write-after-share (docs/67 §4.4, D226) ──────────────────────
// A copy of a buffer does not copy its storage: the storage is shared until a
// write meets it.  A write through any of the bindings must still never be
// seen through another, and a copy must not cost O(n) at the copy.
record Frame {
  var pixels: buffer[Int]
  var tag: Int
}

func readFirst(b: in buffer[Int]): Int {
  b[0]
}

func rebuild(b: in buffer[Int]): buffer[Int] {
  var c = b
  c
}

func setAll(b: inout buffer[Int], v: in Int) {
  var i = 0
  while i < b.length {
    b[i] = v
    i = i + 1
  }
}

func stash(b: in buffer[Int], into: inout Frame): Int {
  into.pixels = b
  0
}

func setFirst[T](b: inout buffer[T], v: in T)
  where T: Plain
{
  b[0] = v
}

func firstOf[T](b: in buffer[T]): T
  where T: Plain
{
  b[0]
}

func copyAndSetFirst[T](b: in buffer[T], v: in T): buffer[T]
  where T: Plain
{
  var c = b
  c[0] = v
  c
}

test "a chain of copies keeps every binding's own value" {
  var a = filled(4, 1)
  var b = a
  var c = b
  c[0] = 3
  b[1] = 2
  a[2] = 9
  assertEqualInt(a[0] + a[1] + a[2] + a[3], 1 + 1 + 9 + 1, "a")
  assertEqualInt(b[0] + b[1] + b[2] + b[3], 1 + 2 + 1 + 1, "b")
  assertEqualInt(c[0] + c[1] + c[2] + c[3], 3 + 1 + 1 + 1, "c")
}

test "writes in both directions after a copy" {
  var a = filled(3, 0)
  var b = a
  a[0] = 1
  b[1] = 2
  a[2] = 3
  b[2] = 4
  assertEqualInt(a[0] * 100 + a[1] * 10 + a[2], 103, "a")
  assertEqualInt(b[0] * 100 + b[1] * 10 + b[2], 24, "b")
}

test "a compound write after a copy leaves the copy alone" {
  var a = filled(2, 10)
  val snapshot = a
  a[0] += 5
  a[1] -= 3
  assertEqualInt(snapshot[0], 10, "snapshot first")
  assertEqualInt(snapshot[1], 10, "snapshot second")
  assertEqualInt(a[0], 15, "a first")
  assertEqualInt(a[1], 7, "a second")
}

test "an inout write after a copy leaves the copy alone" {
  var a = filled(3, 1)
  val snapshot = a
  setAll(a, 9)
  assertEqualInt(snapshot[0] + snapshot[1] + snapshot[2], 3, "snapshot")
  assertEqualInt(a[0] + a[1] + a[2], 27, "a")
}

test "a value that copies the buffer is evaluated before the write checks for sharing" {
  var a = filled(3, 1)
  var f = Frame(pixels = filled(1, 0), tag = 0)
  a[0] = stash(a, f)
  assertEqualInt(a[0], 0, "the write landed")
  assertEqualInt(f.pixels[0], 1, "the copy the call kept did not see it")
  assertEqualInt(f.pixels[2], 1, "and holds the rest")
}

test "a copy held by a record field is not changed by a later write" {
  var a = filled(3, 4)
  var f = Frame(pixels = a, tag = 1)
  a[1] = 40
  f.pixels[2] = 41
  assertEqualInt(f.pixels[1], 4, "the record's copy")
  assertEqualInt(a[2], 4, "the variable")
  assertEqualInt(f.pixels[2], 41, "the record's own write")
}

test "copying a record copies the buffer it holds" {
  var h1 = Frame(pixels = filled(3, 1), tag = 0)
  var h2 = h1.copy(tag = 1)
  h2.pixels[0] = 5
  assertEqualInt(h1.pixels[0], 1, "the original")
  assertEqualInt(h2.pixels[0], 5, "the copy")
}

test "generic functions over a buffer read and write it" {
  var a = filled(3, 2)
  val snapshot = a
  setFirst(a, 8)
  assertEqualInt(firstOf(a), 8, "written")
  assertEqualInt(firstOf(snapshot), 2, "snapshot")
  var f = filled(2, 1.5f32)
  val g = copyAndSetFirst(f, 2.5f32)
  assertTrue(firstOf(f) == 1.5f32, "the argument")
  assertTrue(firstOf(g) == 2.5f32, "the result")
}

test "passing a large buffer to an in parameter does not copy it" {
  var b = filled(50000, 3)
  val before = allocatedBytes()
  var total = 0
  var i = 0
  while i < 20 {
    total = total + readFirst(b)
    i = i + 1
  }
  val used = allocatedBytes() - before
  assertEqualInt(total, 60, "the reads")
  assertTrue(used < 50000i64, "20 in-passes allocated " + used.toString() + " bytes")
}

test "returning a copy of a large buffer does not copy it" {
  var b = filled(50000, 3)
  val before = allocatedBytes()
  var r = rebuild(b)
  val used = allocatedBytes() - before
  assertTrue(used < 50000i64, "rebuilding allocated " + used.toString() + " bytes")
  assertEqualInt(r[49999], 3, "the result")
  r[0] = 4
  assertEqualInt(b[0], 3, "the argument")
  assertEqualInt(r[0], 4, "the result after a write")
}

test "toSlice called as a method reads the buffer, including a call's result" {
  val bytes = fromSlice([1u8, 2u8, 3u8])
  val s = bytes.toSlice()
  assertEqualInt(s.length, 3, "length")
  assertTrue(s[2] == 3u8, "last byte")
  assertEqualInt(fromSlice([4, 5]).toSlice()[1], 5, "a call's result")
  var w = filled(2, 7)
  val t = w.toSlice()
  w[0] = 1
  assertEqualInt(t[0], 7, "the slice is a copy")
}

test "only the first write to a shared buffer copies it" {
  var a = filled(50000, 5)
  var b = a
  val before = allocatedBytes()
  var i = 0
  while i < 1000 {
    b[i] = 1
    i = i + 1
  }
  val used = allocatedBytes() - before
  assertTrue(used > 100000i64, "the first write copied the storage")
  assertTrue(used < 1000000i64, "1000 writes allocated " + used.toString() + " bytes: one copy, not a copy per write")
  assertEqualInt(a[999], 5, "a")
  assertEqualInt(b[999], 1, "b")
}

test "a copy shares storage until the first write, which copies once" {
  var a = filled(50000, 5)
  val before = allocatedBytes()
  var b = a
  val afterCopy = allocatedBytes()
  assertTrue(afterCopy - before < 10000i64, "the copy allocated " + (afterCopy - before).toString() + " bytes")
  b[0] = 1
  val afterWrite = allocatedBytes()
  assertTrue(afterWrite - afterCopy > 100000i64, "the first write copied the storage")
  b[1] = 2
  b[2] = 3
  assertTrue(allocatedBytes() - afterWrite < 10000i64, "later writes are in place")
  assertEqualInt(a[0], 5, "a")
  assertEqualInt(b[0] + b[1] + b[2], 6, "b")
}

test "an array of buffers copies each buffer on write, not on copy" {
  var xs: array[2, buffer[Int]] = [filled(2, 1), filled(2, 2)]
  var ys = xs
  ys[0][0] = 7
  assertEqualInt(xs[0][0], 1, "xs first element")
  assertEqualInt(ys[0][0], 7, "ys first element")
  xs[1][1] = 8
  assertEqualInt(ys[1][1], 2, "ys second element")
  assertEqualInt(xs[1][1], 8, "xs second element")
}

test "a buffer of arrays: a write to an element array does not reach a copy" {
  val row: array[2, Int] = [0, 0]
  var rows = filled(2, row)
  rows[0][1] = 5
  assertEqualInt(rows[0][1], 5, "written element")
  var dup = rows
  dup[0][0] = 9
  assertEqualInt(rows[0][0], 0, "the original row")
  assertEqualInt(dup[0][0], 9, "the copy's row")
  assertEqualInt(dup[0][1], 5, "the copy kept the earlier write")
}

test "a compound write to an element array after a copy leaves the copy alone" {
  val row: array[2, Int] = [10, 20]
  var rows = filled(2, row)
  val snapshot = rows
  rows[1][0] += 5
  rows[1][1] -= 7
  assertEqualInt(snapshot[1][0], 10, "snapshot first")
  assertEqualInt(snapshot[1][1], 20, "snapshot second")
  assertEqualInt(rows[1][0], 15, "rows first")
  assertEqualInt(rows[1][1], 13, "rows second")
}
