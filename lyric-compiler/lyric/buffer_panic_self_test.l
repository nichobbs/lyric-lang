//! `buffer[T]` bounds checks (D185): an index outside `0 ..< b.length` panics
//! with `index <i> out of range for buffer of length <n>` on every target.
//!
//! `assertPanicsWith` catches the panic, which the native target cannot (no
//! unwinding, D-N-003), so this file runs on dotnet and the JVM.  The
//! in-range behaviour is in `buffer_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/buffer_panic_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/buffer_panic_self_test.l
@test_module
package Lyric.BufferPanicSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Buffer

record Holder {
  var cells: buffer[Int]
}

func idx(i: in Int): Int = i

func counted(calls: inout Int, i: in Int): Int {
  calls = calls + 1
  i
}

func readAt(b: in buffer[Int], i: in Int): Int {
  b[i]
}

func writeAt(b: inout buffer[Int], i: in Int, v: in Int) {
  b[i] = v
}

func addAt(b: inout buffer[Int], i: in Int, v: in Int) {
  b[i] += v
}

func fieldAt(h: in Holder, i: in Int): Int {
  h.cells[i]
}

test "a read past either end panics with the index and the length" {
  val b = filled(3, 1)
  assertPanicsWith("past the end", "index 3 out of range for buffer of length 3", { -> val _ = readAt(b, idx(3)) })
  assertPanicsWith(
    "far past the end",
    "index 100 out of range for buffer of length 3",
    { -> val _ = readAt(b, idx(100)) }
  )
  assertPanicsWith(
    "before the start",
    "index -1 out of range for buffer of length 3",
    { -> val _ = readAt(b, idx(-1)) }
  )
  assertEqualInt(readAt(b, idx(0)), 1, "the first element is in range")
  assertEqualInt(readAt(b, idx(2)), 1, "the last element is in range")
}

test "a write past either end panics and changes nothing" {
  var b = filled(3, 1)
  assertPanicsWith("assign past the end", "index 3 out of range for buffer of length 3", { -> writeAt(b, idx(3), 9) })
  assertPanicsWith(
    "assign before the start",
    "index -2 out of range for buffer of length 3",
    { -> writeAt(b, idx(-2), 9) }
  )
  assertPanicsWith("compound past the end", "index 5 out of range for buffer of length 3", { -> addAt(b, idx(5), 1) })
  writeAt(b, idx(1), 20)
  assertEqualInt(b[1], 20, "an in-range write works")
  assertEqualInt(b[0] + b[2], 2, "and touches only its own element")
}

test "an empty buffer and a field's buffer check each index" {
  val e = filled(0, 0)
  assertPanicsWith("an empty buffer", "index 0 out of range for buffer of length 0", { -> val _ = readAt(e, idx(0)) })
  val h = Holder(cells = filled(2, 5))
  assertPanicsWith(
    "a var field's element",
    "index 4 out of range for buffer of length 2",
    { -> val _ = fieldAt(h, idx(4)) }
  )
}

test "the index is evaluated once and before the check" {
  var calls = 0
  val b = filled(3, 7)
  val v = b[counted(calls, 1)]
  assertEqualInt(v, 7, "the element")
  assertEqualInt(calls, 1, "the index expression ran once")
}

test "view and truncate past the end panic on the buffer's own bounds check" {
  val b = filled(3, 1)
  assertPanics("view past the end", { -> val _ = view(b, 0, idx(4)) })
  assertPanics("truncate past the end", { -> val _ = truncate(b, idx(4)) })
}
