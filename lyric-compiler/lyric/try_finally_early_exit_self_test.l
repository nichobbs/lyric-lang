//! try_finally_early_exit_self_test.l — regression test for the JVM backend
//! skipping `finally` on a non-fall-through exit (`return`/`break`/`continue`)
//! from a `try` body or `catch` arm (#5765).
//!
//! `lowerTryCatch` / `lowerTryCatchFinallyExpr` (`lyric-compiler/jvm/codegen/
//! 05_stmts.l`) previously only ran the `finally` block on normal
//! fall-through and on exceptional unwind (via a catch-all handler); an
//! explicit early exit inside the try body or a catch arm emitted its
//! control transfer directly and bypassed the finally block entirely — a
//! silent violation of `try`/`finally`'s guaranteed-cleanup contract that the
//! MSIL backend (whose `leave` opcode automatically runs enclosing `finally`
//! handlers, see `return_in_try_self_test.l`) never had.  The fix pushes the
//! finally block onto the same `ctx.deferStack` the `defer` and `scope { }`
//! constructs already use, so `SReturn`/`SBreak`/`SContinue`'s existing
//! `replayDefers` call runs it before transferring control.
//!
//! Run via native `lyric test` on **both targets** (like
//! `bitwise_self_test.l`): `--target dotnet` exercises the pre-existing
//! (already-correct) `leave`-based epilogue routing as a no-regression
//! check; `--target jvm` is the load-bearing run for this fix. Imports
//! only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/try_finally_early_exit_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/try_finally_early_exit_self_test.l
@test_module
package Lyric.TryFinallyEarlyExitSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// `return` from inside a `try { } finally { }` — the finally must run
// exactly once on every return path.
func returnThroughFinally(log: in List[Int], x: Int): Int {
  try {
    if x > 0 {
      log.add(1)
      return 10
    }
    log.add(2)
    return 20
  } finally {
    log.add(99)
  }
}

// `break` out of a try/finally nested inside a `while` loop must run the
// finally on every iteration, including the one that breaks.
func breakThroughFinally(log: in List[Int]): Int {
  var i = 0
  while i < 5 {
    try {
      if i == 2 {
        break
      }
      log.add(i)
    } finally {
      log.add(100 + i)
    }
    i = i + 1
  }
  i
}

// `continue` out of a try/finally nested inside a `for` loop must run the
// finally on the continued iteration too.
func continueThroughFinally(log: in List[Int]): Int {
  var sum = 0
  for i in 0 ..< 4 {
    try {
      if i == 1 {
        continue
      }
      log.add(i)
    } finally {
      log.add(200 + i)
    }
    sum = sum + i
  }
  sum
}

// `return` from inside a `catch` body must still run an enclosing finally.
func returnThroughCatchFinally(log: in List[Int]): Int {
  try {
    panic("boom")
    99
  } catch Bug as _ {
    log.add(1)
    return 42
  } finally {
    log.add(2)
  }
}

// Nested try/finally: an inner early return must run BOTH finallys, inner
// first, then outer.
func nestedFinallyReturn(log: in List[Int]): Int {
  try {
    try {
      log.add(1)
      return 7
    } finally {
      log.add(2)
    }
  } finally {
    log.add(3)
  }
}

// try/finally in VALUE position (#2043) with an early return inside the try
// body: the finally must run once whether the function returns early or the
// try's own value flows through to the binding.
func valuePositionEarlyReturn(log: in List[Int], x: Int): Int {
  val r = try {
    if x > 0 {
      return 100
    }
    x * 2
  } finally {
    log.add(7)
  }
  r
}

// A genuine exception (no early return involved) must still run the finally
// exactly once and propagate — the pre-existing catch-all path this fix must
// not regress.
func excThroughFinally(log: in List[Int]): Int {
  try {
    try {
      panic("inner")
      1
    } finally {
      log.add(10)
    }
  } catch Bug as _ {
    log.add(11)
    5
  }
}

test "return out of a try/finally runs the finally exactly once" {
  val log1: List[Int] = newList()
  assertEqualInt(returnThroughFinally(log1, 5), 10, "x>0 branch value")
  assertEqualInt(log1.count, 2, "body entry + finally entry, x>0")
  assertEqualInt(log1[0], 1, "body ran before the early return")
  assertEqualInt(log1[1], 99, "finally ran on the early return")

  val log2: List[Int] = newList()
  assertEqualInt(returnThroughFinally(log2, -1), 20, "x<=0 branch value")
  assertEqualInt(log2.count, 2, "body entry + finally entry, x<=0")
  assertEqualInt(log2[1], 99, "finally ran on the second return path too")
}

test "break out of a try/finally inside a loop runs the finally" {
  val log: List[Int] = newList()
  assertEqualInt(breakThroughFinally(log), 2, "loop stops at i == 2")
  // i=0: body logs 0, finally logs 100. i=1: body logs 1, finally logs 101.
  // i=2: break (no body log), finally logs 102.
  assertEqualInt(log.count, 5, "finally ran on every iteration incl. the break")
  assertEqualInt(log[4], 102, "finally ran on the break iteration")
}

test "continue through a try/finally inside a loop runs the finally" {
  val log: List[Int] = newList()
  assertEqualInt(continueThroughFinally(log), 5, "sum skips the continued iteration's contribution")
  // i=0: log 0, finally 200. i=1: continue (no body log), finally 201.
  // i=2: log 2, finally 202. i=3: log 3, finally 203.
  assertEqualInt(log.count, 7, "finally ran on every iteration incl. the continue")
  assertEqualInt(log[2], 201, "finally ran on the continued iteration")
}

test "return from a catch body still runs an enclosing finally" {
  val log: List[Int] = newList()
  assertEqualInt(returnThroughCatchFinally(log), 42, "catch-body return value")
  assertEqualInt(log.count, 2, "catch body ran then finally ran")
  assertEqualInt(log[0], 1, "catch body entry")
  assertEqualInt(log[1], 2, "finally entry")
}

test "nested try/finally both run on an inner early return" {
  val log: List[Int] = newList()
  assertEqualInt(nestedFinallyReturn(log), 7, "inner return value propagates")
  assertEqualInt(log.count, 3, "inner body + both finallys ran")
  assertEqualInt(log[0], 1, "inner body entry")
  assertEqualInt(log[1], 2, "inner finally ran first")
  assertEqualInt(log[2], 3, "outer finally ran second")
}

test "value-position try/finally runs the finally on an early return" {
  val log1: List[Int] = newList()
  assertEqualInt(valuePositionEarlyReturn(log1, 5), 100, "early-return value")
  assertEqualInt(log1.count, 1, "finally ran exactly once on early return")

  val log2: List[Int] = newList()
  assertEqualInt(valuePositionEarlyReturn(log2, -3), -6, "fall-through value")
  assertEqualInt(log2.count, 1, "finally ran exactly once on fall-through too")
}

test "a genuine exception through nested try/finally still runs the finally once" {
  val log: List[Int] = newList()
  assertEqualInt(excThroughFinally(log), 5, "outer catch value")
  assertEqualInt(log.count, 2, "inner finally ran once, then outer catch ran")
  assertEqualInt(log[0], 10, "inner finally ran on the exception path")
  assertEqualInt(log[1], 11, "outer catch ran after the finally")
}
