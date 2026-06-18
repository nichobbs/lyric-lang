//! defer_self_test.l — executable regression tests for `defer`-at-scope-exit on
//! the self-hosted MSIL target (#1477; epic #1470, Band 2).
//!
//! `defer { D }` runs D on scope exit on EVERY path — normal fall-off, early
//! `return`, `break`/`continue`, and exception unwind (grammar: "runs on scope
//! exit, success or failure") — and multiple defers run in reverse declaration
//! order.  Previously `SDefer` ran its body inline at the declaration point, so
//! it executed too early and never on the return / exception paths.  Codegen now
//! lowers the statements following a `defer` as `try { rest } finally { D }`,
//! reusing the function-epilogue return lowering (D-progress-373) and the
//! break/continue-`leave` lowering (D-progress-371) so the finally runs on those
//! exits too.
//!
//! Run via native `lyric test --target dotnet`.  Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/defer_self_test.l
//!
//! Observation uses a `List[Int]` log (a reference type, so appends are visible
//! to the caller).  MSIL target only; JVM parity is tracked under epic #1470's
//! JVM-deferral note.
@test_module
package Lyric.DeferSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// Normal fall-off, multiple defers → reverse declaration order.
func reverseOrder(log: in List[Int]): Unit {
  defer {
    log.add(1)
  }
  defer {
    log.add(2)
  }
  log.add(0)
}

// `defer` runs on an early `return` (value-returning function).
func deferOnReturn(log: in List[Int], x: in Int): Int {
  defer {
    log.add(9)
  }
  if x > 0 {
    return 5
  }
  10
}

// `defer` runs on `break` out of the enclosing loop.  The defer is declared
// inside the loop body, so it runs once per iteration at the end of that body
// (including the iteration that breaks).
func deferOnBreak(log: in List[Int]): Unit {
  var i = 0
  while i < 5 {
    // Snapshot the iteration number into a per-iteration `val` so the assertion
    // does not depend on the deferred block reading `i` after its in-body
    // increment (a `defer` block reads variables at scope-exit time).
    val mark = 100 + i
    defer {
      log.add(mark)
    }
    if i == 2 {
      break
    }
    i = i + 1
  }
}

// `defer` runs on `continue`.
func deferOnContinue(log: in List[Int]): Unit {
  var i = 0
  while i < 3 {
    val cur = i
    i = i + 1
    defer {
      log.add(200 + cur)
    }
    if cur == 1 {
      continue
    }
    log.add(cur)
  }
}

// A void function whose deferred block runs while an exception unwinds through
// its scope (the caller catches).  Demonstrates the success-or-failure contract.
func deferThenPanic(log: in List[Int]): Unit {
  defer {
    log.add(8)
  }
  panic("boom")
}

func runWithPanic(log: in List[Int]): Unit {
  try {
    deferThenPanic(log)
  } catch Bug as _ {
    log.add(7)
  }
}

// `defer` inside a value-producing sub-block (an `if`-branch used as a value):
// directly exercises the trailing-value defer path (`lowerStmtsExprFromMsil`),
// where the block value must survive the `leave` while the deferred block runs.
func deferInValueBlock(log: in List[Int]): Int {
  val r = if true { defer { log.add(5) }; 7 } else { 0 }
  r
}

test "multiple defers run in reverse declaration order on fall-off" {
  val log: List[Int] = newList()
  reverseOrder(log)
  assertEqualInt(log.count, 3, "three appends")
  assertEqualInt(log[0], 0, "body runs first")
  assertEqualInt(log[1], 2, "second defer runs before first")
  assertEqualInt(log[2], 1, "first defer runs last")
}

test "defer runs on an early return and the value is preserved" {
  val log1: List[Int] = newList()
  assertEqualInt(deferOnReturn(log1, 1), 5, "early-return value")
  assertEqualInt(log1.count, 1, "defer ran on return")
  assertEqualInt(log1[0], 9, "deferred append")
  val log2: List[Int] = newList()
  assertEqualInt(deferOnReturn(log2, -1), 10, "fall-through value")
  assertEqualInt(log2[0], 9, "defer ran on fall-through too")
}

test "defer runs on break out of a loop" {
  val log: List[Int] = newList()
  deferOnBreak(log)
  // iterations i=0,1,2; each body's defer runs at body exit -> 100,101,102.
  assertEqualInt(log.count, 3, "three deferred appends")
  assertEqualInt(log[0], 100, "iteration 0")
  assertEqualInt(log[1], 101, "iteration 1")
  assertEqualInt(log[2], 102, "iteration 2 (the break iteration)")
}

test "defer runs on continue" {
  val log: List[Int] = newList()
  deferOnContinue(log)
  // i=0: append 0, defer 200; i=1: continue, defer 201; i=2: append 2, defer 202.
  assertEqualInt(log.count, 5, "appends + defers")
  assertEqualInt(log[0], 0, "i=0 body")
  assertEqualInt(log[1], 200, "i=0 defer")
  assertEqualInt(log[2], 201, "i=1 defer (continue path)")
  assertEqualInt(log[3], 2, "i=2 body")
  assertEqualInt(log[4], 202, "i=2 defer")
}

test "defer runs while an exception unwinds through its scope" {
  val log: List[Int] = newList()
  runWithPanic(log)
  assertEqualInt(log.count, 2, "defer + catch")
  assertEqualInt(log[0], 8, "deferred cleanup runs during unwind")
  assertEqualInt(log[1], 7, "caller's catch runs after")
}

test "defer inside a value-producing block runs on block exit, value preserved" {
  val log: List[Int] = newList()
  val r = deferInValueBlock(log)
  assertEqualInt(r, 7, "branch value preserved across the deferred block")
  assertEqualInt(log.count, 1, "defer ran on block exit")
  assertEqualInt(log[0], 5, "deferred append")
}
