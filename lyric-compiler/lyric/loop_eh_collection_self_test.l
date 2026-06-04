// loop_eh_collection_self_test.l — executable regression tests for the
// remaining two #1481 (epic #1470, Band 2) self-hosted MSIL backend fixes:
//
//   Item 3 — break/continue across a `try` region must emit `leave`.  A
//   `break`/`continue` whose target loop was entered *outside* an enclosing
//   `try`/`catch` jumps across a CLR protected-region boundary; the backend
//   previously emitted a plain `br`, which is unverifiable IL
//   (`InvalidProgramException` at JIT time).  The fix tracks protected-region
//   nesting depth and emits `leave` when the jump escapes one or more open
//   regions.
//
//   Item 4 — `List.contains` / `List.removeAt` BCL stubs.  `xs.contains(v)`
//   previously popped its argument and pushed `false` (every membership test
//   wrong); `xs.removeAt(i)` popped and did nothing (silent no-op).  Both now
//   emit the real `List<object>::Contains(object)` / `RemoveAt(int32)` calls.
//
// Run via native `lyric test --target dotnet` — compiled in-process through the
// self-hosted `Msil.Bridge`.  Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
//
//   lyric test lyric-compiler/lyric/loop_eh_collection_self_test.l
//
// MSIL target only; JVM parity is tracked under epic #1470's JVM-deferral note.

@test_module
package Lyric.LoopEhCollectionSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Item 3 — break / continue out of a `try` body (must lower to `leave`).
// ─────────────────────────────────────────────────────────────────────────────

// `break` from inside a `try` whose enclosing loop sits outside the protected
// region.  Sums elements until the first negative, then breaks out of both the
// try and the while.
func sumUntilNeg(xs: in List[Int]): Int {
  var total = 0
  var i = 0
  while i < xs.count {
    try {
      if xs[i] < 0 {
        break
      }
      total += xs[i]
    } catch Bug as _ {
      total = total - 1000
    }
    i += 1
  }
  total
}

// `continue` from inside a `try` whose enclosing loop sits outside the
// protected region.  Skips negative elements (the counter is advanced before
// the try so the `continue` cannot loop forever).
func sumSkipNeg(xs: in List[Int]): Int {
  var total = 0
  var i = 0
  while i < xs.count {
    val cur = xs[i]
    i += 1
    try {
      if cur < 0 {
        continue
      }
      total += cur
    } catch Bug as _ {
      total = total - 1000
    }
  }
  total
}

test "break out of a try region exits the loop (emits leave, not br)" {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  xs.add(3)
  xs.add(-9)
  xs.add(100)
  // 1 + 2 + 3 then break at -9 (100 never added).
  assertEqualInt(sumUntilNeg(xs), 6, "sum until first negative")
}

test "continue out of a try region re-tests the loop (emits leave, not br)" {
  val xs: List[Int] = newList()
  xs.add(5)
  xs.add(-1)
  xs.add(7)
  xs.add(-2)
  xs.add(8)
  // 5 + 7 + 8; the two negatives are skipped via `continue`.
  assertEqualInt(sumSkipNeg(xs), 20, "sum skipping negatives")
}

// `continue` from inside a *catch handler* body — the catch is itself a CLR
// protected region, so the escape must also lower to `leave`, not `br`.  Each
// negative element raises a `Bug` (via `panic`); the catch handler skips it
// with `continue`.
func sumSkipBugs(xs: in List[Int]): Int {
  var total = 0
  var i = 0
  while i < xs.count {
    val cur = xs[i]
    i += 1
    try {
      if cur < 0 {
        panic("neg")
      }
      total += cur
    } catch Bug as _ {
      continue
    }
  }
  total
}

// `break` from inside a *catch handler* body — same protected-region escape
// rule as above, exiting the loop entirely on the first raised Bug.
func sumUntilBug(xs: in List[Int]): Int {
  var total = 0
  var i = 0
  while i < xs.count {
    try {
      if xs[i] < 0 {
        panic("neg")
      }
      total += xs[i]
      i += 1
    } catch Bug as _ {
      break
    }
  }
  total
}

test "continue inside a catch handler emits leave, not br" {
  val xs: List[Int] = newList()
  xs.add(5)
  xs.add(-1)
  xs.add(7)
  xs.add(-2)
  xs.add(8)
  // 5 + 7 + 8 — the catch handler `continue`s past the two negatives.
  assertEqualInt(sumSkipBugs(xs), 20, "sum skipping bugs from catch continue")
}

test "break inside a catch handler emits leave, not br" {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  xs.add(-9)
  xs.add(100)
  // 1 + 2 then the catch handler `break`s out on -9 (100 never reached).
  assertEqualInt(sumUntilBug(xs), 3, "sum until break from catch")
}

// ─────────────────────────────────────────────────────────────────────────────
// Item 4 — List.contains / List.removeAt real BCL calls.
// ─────────────────────────────────────────────────────────────────────────────

test "List.contains reflects membership" {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  assertTrue(xs.contains(20), "contains present element")
  assertTrue(not xs.contains(99), "does not contain absent element")
}

test "List.contains works for String elements" {
  val ss: List[String] = newList()
  ss.add("alpha")
  ss.add("beta")
  assertTrue(ss.contains("beta"), "contains 'beta'")
  assertTrue(not ss.contains("gamma"), "does not contain 'gamma'")
}

test "List.removeAt removes the element at the index" {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  xs.removeAt(1)
  assertEqualInt(xs.count, 2, "count after removeAt")
  assertEqualInt(xs[0], 10, "element 0 after removeAt")
  assertEqualInt(xs[1], 30, "element 1 after removeAt")
}
