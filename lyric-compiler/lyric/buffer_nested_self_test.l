//! A `buffer[T]` nested with an array: a buffer of arrays and an array of
//! buffers (D226, docs/67 §4.4).  A copy shares the buffers; a write to an
//! element array, or to a buffer held by an array, makes the storage it meets
//! private first, and never reaches a copy.
//!
//! Runs on dotnet and the JVM.  `--target native` does not yet write an element
//! array inside a buffer, or a buffer held by an array (N0007, a `[N x T]` or
//! `__buffer<T>` receiver of an indexed assignment), so these two shapes are
//! pinned here and not in `buffer_self_test.l`, which every target runs (#8521).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/buffer_nested_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/buffer_nested_self_test.l
@test_module
package Lyric.BufferNestedSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Buffer

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
