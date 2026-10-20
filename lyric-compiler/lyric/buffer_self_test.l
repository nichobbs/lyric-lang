//! `buffer[T]` (D185, docs/67 §4.4): a contiguous, runtime-length sequence of
//! `Plain` elements with value semantics, the same behaviour on every target.
//!
//! Construction, indexing, element writes through a `var` local, a `var`
//! field and an `inout` parameter, copies on assignment, passing and
//! returning (a write through one binding is never seen through another),
//! `.length`, `for x in b`, the `Std.Buffer` functions, and the bounds panic.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/buffer_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/buffer_self_test.l
@test_module
package Lyric.BufferSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Buffer

record Vec3 {
  x: Float
  y: Float
  z: Float
}

record Mesh {
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
