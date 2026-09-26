//! labelled_loops_self_test.l — `label: for|while|do` with `break label` /
//! `continue label` (#7349).
//!
//! Before #7349 a labelled loop was a parse error, while `break outer` /
//! `continue outer` parsed and every backend ignored the label, so the jump
//! silently targeted the innermost loop. Each case below exits or continues
//! an outer loop from an inner one and checks the result; the `defer` cases
//! check that every loop the jump leaves runs its deferred blocks, innermost
//! first. The compile-time half (T0130 for a label that names no enclosing
//! loop or a jump outside a loop, T0131 for a label reused by a nested loop)
//! is covered in `typechecker_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/labelled_loops_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/labelled_loops_self_test.l
//!   lyric test --target native lyric-compiler/lyric/labelled_loops_self_test.l
@test_module
package Lyric.LabelledLoopsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// The first (x, y) pair with x * y == target, as x * 100 + y; -1 if none.
func findPair(xs: in List[Int], ys: in List[Int], target: in Int): Int {
  var found = -1
  outer: for x in xs {
    for y in ys {
      if x * y == target {
        found = x * 100 + y
        break outer
      }
    }
  }
  found
}

// Rows whose every cell is non-negative, counted with `continue outer`.
func countCleanRows(rows: in List[List[Int]]): Int {
  var clean = 0
  var r = 0
  nextRow: while r < rows.count {
    val row = rows[r]
    r = r + 1
    var c = 0
    while c < row.count {
      if row[c] < 0 {
        continue nextRow
      }
      c = c + 1
    }
    clean = clean + 1
  }
  clean
}

// `break outer` out of a `do` loop nested in a `while`, with an unlabelled
// `break` alongside that must still leave only the innermost loop.
func doInWhile(log: in List[Int]): Int {
  var i = 0
  var steps = 0
  outer: while i < 10 {
    i = i + 1
    var j = 0
    do {
      j = j + 1
      steps = steps + 1
      if j == 3 {
        break
      }
      if i == 4 and j == 2 {
        break outer
      }
    }
    log.add(i)
  }
  steps
}

// `continue outer` from a labelled `do` inside a range `for`.
func continueFromDo(n: in Int): Int {
  var total = 0
  outer: for i in 0 ..< n {
    var k = 0
    do {
      k = k + 1
      if k > i {
        continue outer
      }
      total = total + 1
    }
  }
  total
}

// Three nested loops; `break mid` leaves the innermost two and resumes the
// outermost, `continue top` skips the rest of the outermost's iteration.
func threeLevels(log: in List[Int]): Unit {
  top: for a in [1, 2, 3] {
    mid: for b in [10, 20, 30] {
      for c in [100, 200] {
        if b == 20 {
          break mid
        }
        if a == 2 {
          continue top
        }
        log.add(a + b + c)
      }
    }
    log.add(a)
  }
}

// A labelled jump out of a `match` arm and an `if` in the inner loop.
func jumpFromMatch(xs: in List[Option[Int]]): Int {
  var sum = 0
  outer: for x in xs {
    for _ in [1, 2] {
      match x {
        case Some(v) -> {
          if v < 0 {
            break outer
          }
          sum = sum + v
          continue outer
        }
        case None -> continue outer
      }
    }
  }
  sum
}

// Every loop the jump leaves runs its `defer`s, innermost first; loops the
// jump stays inside do not run theirs early.
func defersOnBreakOuter(log: in List[Int]): Unit {
  outer: for i in [1, 2] {
    defer {
      log.add(i * 10)
    }
    for j in [1, 2] {
      defer {
        log.add(i * 100 + j)
      }
      if i == 2 {
        break outer
      }
    }
  }
  log.add(0)
}

func defersOnContinueOuter(log: in List[Int]): Unit {
  outer: for i in [1, 2] {
    defer {
      log.add(i * 10)
    }
    var j = 0
    while true {
      j = j + 1
      defer {
        log.add(i * 100 + j)
      }
      continue outer
    }
  }
  log.add(0)
}

// The same label on sibling (not nested) loops is allowed.
func siblingLabels(): Int {
  var n = 0
  scan: for x in [1, 2, 3] {
    if x == 2 {
      break scan
    }
    n = n + x
  }
  scan: for x in [4, 5, 6] {
    if x == 5 {
      continue scan
    }
    n = n + x
  }
  n
}

// A loop in a `defer` or lambda body may reuse an enclosing loop's label;
// leaving it must not forget the outer one (#7394). `continue outer`
// replays the defer, whose own `outer` loop runs inside the jump.
func shadowedInDefer(): Int {
  var n = 0
  outer: while n < 5 {
    defer {
      outer: while false {
        break outer
      }
    }
    n = n + 1
    if n == 2 {
      continue outer
    }
    if n == 4 {
      break outer
    }
  }
  n
}

func shadowedInLambda(): Int {
  var total = 0
  outer: for i in [1, 2, 3, 4] {
    val f: (Int) -> Int = { k: Int ->
      var hits = 0
      outer: for j in [1, 2, 3] {
        if j > k {
          break outer
        }
        hits = hits + 1
      }
      hits
    }
    total = total + f(i)
    if i == 3 {
      break outer
    }
  }
  total
}

test "break outer leaves both loops at the first match" {
  assertEqualInt(findPair([1, 2, 3, 4], [5, 6, 7], 12), 206, "2 * 6 is the first pair")
  assertEqualInt(findPair([1, 2], [3], 100), -1, "no pair")
}

test "continue outer skips the rest of the outer iteration" {
  val rows: List[List[Int]] = newList()
  rows.add([1, 2, 3])
  rows.add([4, -1, 6])
  rows.add([7, 8])
  rows.add([-9])
  assertEqualInt(countCleanRows(rows), 2, "two rows without a negative cell")
}

test "break outer from a do loop; unlabelled break stays innermost" {
  val log: List[Int] = newList()
  assertEqualInt(doInWhile(log), 11, "3 steps for i = 1..3, then 2 before break outer")
  assertEqualInt(log.count, 3, "the while body finished for i = 1..3 only")
  assertEqualInt(log[2], 3, "last completed outer iteration")
}

test "continue outer from a do loop inside a range for" {
  assertEqualInt(continueFromDo(4), 6, "0 + 1 + 2 + 3")
}

test "break and continue across three levels" {
  val log: List[Int] = newList()
  threeLevels(log)
  assertEqualInt(log.count, 6, "entries")
  assertEqualInt(log[0], 111, "a=1 b=10 c=100")
  assertEqualInt(log[1], 211, "a=1 b=10 c=200")
  assertEqualInt(log[2], 1, "a=1 resumes after break mid")
  assertEqualInt(log[3], 113, "a=3 b=10 c=100")
  assertEqualInt(log[4], 213, "a=3 b=10 c=200")
  assertEqualInt(log[5], 3, "a=3 resumes after break mid; a=2 skipped by continue top")
}

test "labelled jumps from inside a match arm" {
  val xs: List[Option[Int]] = newList()
  xs.add(Some(value = 4))
  xs.add(None)
  xs.add(Some(value = 5))
  xs.add(Some(value = -1))
  xs.add(Some(value = 100))
  assertEqualInt(jumpFromMatch(xs), 9, "each value counted once, stops at the negative")
}

test "break outer runs the defers of every loop it leaves" {
  val log: List[Int] = newList()
  defersOnBreakOuter(log)
  assertEqualInt(log.count, 6, "entries")
  assertEqualInt(log[0], 101, "i=1 j=1")
  assertEqualInt(log[1], 102, "i=1 j=2")
  assertEqualInt(log[2], 10, "i=1 outer defer")
  assertEqualInt(log[3], 201, "inner defer first on break outer")
  assertEqualInt(log[4], 20, "then the outer loop's defer")
  assertEqualInt(log[5], 0, "after the loop")
}

test "continue outer runs the inner loop's defers" {
  val log: List[Int] = newList()
  defersOnContinueOuter(log)
  assertEqualInt(log.count, 5, "entries")
  assertEqualInt(log[0], 101, "i=1 inner defer")
  assertEqualInt(log[1], 10, "i=1 outer defer")
  assertEqualInt(log[2], 201, "i=2 inner defer")
  assertEqualInt(log[3], 20, "i=2 outer defer")
  assertEqualInt(log[4], 0, "after the loop")
}

test "sibling loops may reuse a label" {
  assertEqualInt(siblingLabels(), 11, "1 + 4 + 6")
}

test "a label reused inside a defer or lambda does not hide the outer loop (#7394)" {
  assertEqualInt(shadowedInDefer(), 4, "break outer after the defer's own outer loop ran")
  assertEqualInt(shadowedInLambda(), 6, "1 + 2 + 3, then break outer at i = 3")
}
