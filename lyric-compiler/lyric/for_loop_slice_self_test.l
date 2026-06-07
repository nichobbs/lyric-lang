//! for_loop_slice_self_test.l — regression coverage for for-loop iteration
//! over slice[T] from List.toArray() (issue #2563).
//!
//! Verifies that `for x in xs` works correctly when `xs` is a slice[T]
//! derived from List.toArray(), ensuring the loop properly iterates
//! over the list elements without type or binding issues.
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
