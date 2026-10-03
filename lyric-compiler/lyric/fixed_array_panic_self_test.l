//! `array[N, T]` bounds checks (D167): an index outside `0 ..< N` panics with
//! `index <i> out of range for array[<N>]` on every target, and an index whose
//! range-subtype type proves the access does not.
//!
//! `assertPanicsWith` catches the panic, which the native target cannot (no
//! unwinding, D-N-003), so this file runs on dotnet and the JVM;
//! `scripts/ci/fixed-array-e2e.sh` checks the native panic by running a
//! program.  The in-range behaviour is in `fixed_array_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/fixed_array_panic_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/fixed_array_panic_self_test.l
@test_module
package Lyric.FixedArrayPanicSelfTest

import Std.Core
import Std.Collections
import Std.Testing

type Slot = Int range 0 ..= 2

record Holder {
  var cells: array[3, Int]
}

func idx(i: in Int): Int = i

func counted(calls: inout Int, i: in Int): Int {
  calls = calls + 1
  i
}

func readAt(a: in array[3, Int], i: in Int): Int {
  a[i]
}

func writeAt(a: inout array[3, Int], i: in Int, v: in Int) {
  a[i] = v
}

func addAt(a: inout array[3, Int], i: in Int, v: in Int) {
  a[i] += v
}

func writeLocal(i: in Int) {
  var a: array[3, Int] = [1, 2, 3]
  writeAt(a, i, 9)
}

func addLocal(i: in Int) {
  var a: array[3, Int] = [1, 2, 3]
  addAt(a, i, 1)
}

func nestedAt(g: in array[2, array[3, Int]], r: in Int, c: in Int): Int {
  g[r][c]
}

func fieldAt(h: in Holder, i: in Int): Int {
  h.cells[i]
}

func emptyAt(a: in array[0, Int], i: in Int): Int {
  a[i]
}

func slotAt(a: in array[3, Int], s: in Slot): Int {
  a[s]
}

test "a read past either end panics with the index and the length" {
  val a: array[3, Int] = [1, 2, 3]
  assertPanicsWith("past the end", "index 3 out of range for array[3]", { -> val _ = readAt(a, idx(3)) })
  assertPanicsWith("far past the end", "index 100 out of range for array[3]", { -> val _ = readAt(a, idx(100)) })
  assertPanicsWith("before the start", "index -1 out of range for array[3]", { -> val _ = readAt(a, idx(-1)) })
  assertEqualInt(readAt(a, idx(0)), 1, "the first element is in range")
  assertEqualInt(readAt(a, idx(2)), 3, "the last element is in range")
}

test "a write past either end panics and changes nothing" {
  assertPanicsWith("assign past the end", "index 3 out of range for array[3]", { -> writeLocal(idx(3)) })
  assertPanicsWith("assign before the start", "index -2 out of range for array[3]", { -> writeLocal(idx(-2)) })
  assertPanicsWith("compound past the end", "index 5 out of range for array[3]", { -> addLocal(idx(5)) })
  var a: array[3, Int] = [1, 2, 3]
  writeAt(a, idx(1), 20)
  assertEqualInt(a[1], 20, "an in-range write works")
  assertEqualInt(a[0] + a[2], 4, "and touches only its own element")
}

test "nested arrays, fields and an empty array check each index" {
  val g: array[2, array[3, Int]] = [[1, 2, 3], [4, 5, 6]]
  assertPanicsWith("outer index", "index 2 out of range for array[2]", { -> val _ = nestedAt(g, idx(2), 0) })
  assertPanicsWith("inner index", "index 3 out of range for array[3]", { -> val _ = nestedAt(g, 1, idx(3)) })
  assertEqualInt(nestedAt(g, idx(1), idx(2)), 6, "in range")
  val h = Holder()
  assertPanicsWith("a var field's element", "index 4 out of range for array[3]", { -> val _ = fieldAt(h, idx(4)) })
  val e: array[0, Int] = []
  assertPanicsWith("an empty array", "index 0 out of range for array[0]", { -> val _ = emptyAt(e, idx(0)) })
}

test "the index is evaluated once and before the check" {
  var calls = 0
  val a: array[3, Int] = [7, 8, 9]
  val v = a[counted(calls, 1)]
  assertEqualInt(v, 8, "the element")
  assertEqualInt(calls, 1, "the index expression ran once")
}

test "a range-subtype index never panics" {
  val a: array[3, Int] = [4, 5, 6]
  assertEqualInt(slotAt(a, Slot.from(0)), 4, "lowest")
  assertEqualInt(slotAt(a, Slot.from(2)), 6, "highest")
  assertPanics("a value outside the range cannot be made", { -> val _ = Slot.from(idx(3)) })
}

type Big = ULong range 0 ..= 18446744073709551615u64

func readBig(a: in array[3, Int], i: in Big): Int {
  a[i]
}

func readLong(a: in array[3, Int], i: in Long): Int {
  a[i]
}

func addCounted(i: in Int) {
  var a: array[3, Int] = [1, 2, 3]
  var calls = 0
  a[counted(calls, i)] += 1
}

test "a Long index and a compound assignment through a call index panic the same way" {
  val a: array[3, Int] = [1, 2, 3]
  assertPanicsWith("a Long past the end", "index 5 out of range for array[3]", { -> val _ = readLong(a, 5i64) })
  assertPanicsWith("a negative Long", "index -2 out of range for array[3]", { -> val _ = readLong(a, 0i64 - 2i64) })
  assertEqualInt(readLong(a, 2i64), 3, "a Long in range")
  assertPanicsWith("a call index in a compound assignment", "index 4 out of range for array[3]", { -> addCounted(4) })
}

test "a ULong range whose upper bound is 2^64 - 1 is bounds checked" {
  val a: array[3, Int] = [1, 2, 3]
  assertEqualInt(readBig(a, Big.from(2u64)), 3, "in range")
  assertPanicsWith(
    "a large ULong",
    "index 4294967297 out of range for array[3]",
    { -> val _ = readBig(a, Big.from(4294967297u64)) }
  )
}
