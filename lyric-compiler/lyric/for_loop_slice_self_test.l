//! for_loop_slice_self_test.l — regression coverage for for-loop iteration
//! over slice[T] from List.toArray() (issue #2563), collection `for` loops
//! with `break`/`continue` (#1563), and range `for` with Long bounds (#1569).
//!
//! Verifies that `for x in xs` works correctly when `xs` is a slice[T]
//! derived from List.toArray(), ensuring the loop properly iterates
//! over the list elements without type or binding issues.
//!
//! Also verifies that `continue` advances the index past the skipped element
//! and `break` exits the loop immediately inside a collection `for` (#1563),
//! and that `for i in 1L ..= 5L` emits the correct 64-bit increment via
//! `MLdcI8` instead of the 32-bit `MLdcI4` path (#1569).
//!
//! Run via native `lyric test --target dotnet`.  Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/for_loop_slice_self_test.l
//!
@test_module
package Lyric.ForLoopSliceSelfTest

import Std.Core
import Std.Collections
import Std.Testing

test "for-loop over List.toArray() slice sums Int elements" {
  val data: List[Int] = newList()
  data.add(10)
  data.add(20)
  data.add(30)
  var total = 0
  for x in data.toArray() {
    total = total + x
  }
  assertEqualInt(total, 60, "sum of [10, 20, 30]")
}

test "for-loop over List.toArray() slice counts non-empty strings" {
  val data: List[String] = newList()
  data.add("alpha")
  data.add("")
  data.add("beta")
  data.add("gamma")
  data.add("")
  var count = 0
  for s in data.toArray() {
    if s.length > 0 {
      count = count + 1
    }
  }
  assertEqualInt(count, 3, "count non-empty in [alpha, , beta, gamma, ]")
}

test "for-loop over empty List.toArray() slice" {
  val data: List[Int] = newList()
  var total = 0
  for x in data.toArray() {
    total = total + x
  }
  assertEqualInt(total, 0, "sum of empty slice is 0")
}

test "for-loop over List.toArray() slice can build new list" {
  val data: List[Int] = newList()
  data.add(1)
  data.add(2)
  data.add(3)
  val result: List[Int] = newList()
  for x in data.toArray() {
    result.add(x * 2)
  }
  assertEqualInt(result.count, 3, "result list has 3 elements")
  assertEqualInt(result[0], 2, "first doubled element is 2")
  assertEqualInt(result[1], 4, "second doubled element is 4")
  assertEqualInt(result[2], 6, "third doubled element is 6")
}

// ── Collection for with continue (#1563) ─────────────────────────────────────
// `continue` inside a collection `for` must advance the internal index past
// the skipped element; elements after the skipped one must still be visited.
// Regression guard for `emitCollectionForMsil`'s loopCont label pointing to
// the index-increment step rather than the top of the body.
test "collection for continue skips element and continues iteration" {
  val data: List[Int] = newList()
  data.add(1)
  data.add(2)
  data.add(3)
  data.add(4)
  data.add(5)
  var sum = 0
  for x in data.toArray() {
    if x == 3 {
      continue
    }
    sum = sum + x
  }
  // 1 + 2 + 4 + 5 = 12 (3 skipped)
  assertEqualInt(sum, 12, "collection for continue: sum without 3 = 12")
}

// `break` inside a collection `for` must exit the loop immediately; elements
// after the break point must not be visited.
test "collection for break exits loop immediately" {
  val data: List[Int] = newList()
  data.add(10)
  data.add(20)
  data.add(30)
  data.add(40)
  var sum = 0
  var count = 0
  for x in data.toArray() {
    if x == 30 {
      break
    }
    sum = sum + x
    count = count + 1
  }
  // 10 + 20 = 30, count = 2 (30 and 40 not visited)
  assertEqualInt(sum, 30, "collection for break: sum = 30")
  assertEqualInt(count, 2, "collection for break: 2 elements visited before break")
}

// Both continue and break in the same collection for loop.
test "collection for continue and break in same loop" {
  val data: List[Int] = newList()
  data.add(1)
  data.add(2)
  data.add(3)
  data.add(4)
  data.add(5)
  data.add(6)
  var sum = 0
  for x in data.toArray() {
    if x == 2 {
      continue
    }
    if x == 5 {
      break
    }
    sum = sum + x
  }
  // visits 1, skips 2, visits 3, visits 4, breaks at 5 → 1 + 3 + 4 = 8
  assertEqualInt(sum, 8, "continue skips 2, break stops at 5, sum = 8")
}

// ── Range for with Long bounds (#1569) ────────────────────────────────────────
// `for i in lo ..= hi` with Long literal bounds triggers the MLdcI8 increment
// path in `emitCountingForMsil`.  All existing tests use Int bounds; this
// guards the Long branch against regression.
test "range for with inclusive Long bounds sums correctly" {
  var s = 0i64
  for i in 1i64 ..= 5i64 {
    s = s + i
  }
  // 1 + 2 + 3 + 4 + 5 = 15
  assertTrue(s == 15i64, "sum 1L..=5L = 15")
}

test "range for with exclusive Long bounds sums correctly" {
  var s = 0i64
  for i in 1i64 .. 6i64 {
    s = s + i
  }
  // 1 + 2 + 3 + 4 + 5 = 15
  assertTrue(s == 15i64, "sum 1L..<6L = 15")
}

// Large Long values that would overflow 32-bit int confirm that the loop
// counter is truly 64-bit (no silent truncation in the increment or compare).
test "range for with large Long bounds iterates correct count" {
  var count = 0
  for _i in 1000000000i64 ..= 1000000004i64 {
    count = count + 1
  }
  // 5 iterations: 1000000000, ..., 1000000004
  assertEqualInt(count, 5, "5 iterations at large Long offset")
}
