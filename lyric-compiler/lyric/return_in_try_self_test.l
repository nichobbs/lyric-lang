//! return_in_try_self_test.l — regression tests for returning out of a CLR
//! protected region on the self-hosted MSIL target (#1477 foundation; epic
//! #1470, Band 2).
//!
//! A `return` lowered inside a `try`/`catch`/`finally` previously emitted a bare
//! `ret`, which is unverifiable IL out of a protected region — every such
//! program faulted the JIT (`InvalidProgramException`).  Codegen now routes a
//! `return` that escapes ≥1 open region through a single function epilogue: it
//! stashes the value into a synthetic local and `leave`s to the epilogue (which
//! runs any intervening `finally` before loading the value and returning).  This
//! is the enabling fix for `defer`-at-scope-exit (the `try { rest } finally { D }`
//! lowering), landing separately because it is an independent correctness fix.
//!
//! Run via native `lyric test --target dotnet`.  Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/return_in_try_self_test.l
//!
//! MSIL target only; JVM parity is tracked under epic #1470's JVM-deferral note.
@test_module
package Lyric.ReturnInTrySelfTest

import Std.Core
import Std.Testing

// `return` from inside a `try { ... } finally { ... }` — the finally must run,
// and the value must survive it.
func returnThroughFinally(x: Int): Int {
  try {
    if x > 0 {
      return 10
    }
    return 20
  } finally {
    // side-effect-only finally; the returned value is unaffected.
    ()
  }
}

// `return` from inside a `try` whose handler is a `catch` (no finally).
func returnThroughCatch(x: Int): Int {
  try {
    if x > 0 {
      return 1
    }
    return 2
  } catch Bug as _ {
    return 3
  }
}

// `return` from inside a `catch` handler body (the handler is itself a
// protected-region context that requires `leave`).
func returnFromCatchBody(): Int {
  try {
    panic("boom")
    99
  } catch Bug as _ {
    return 42
  }
}

// Nested try/finally: both finallys run, the innermost return value propagates.
func nestedFinally(): Int {
  try {
    try {
      return 7
    } finally {
      ()
    }
  } finally {
    ()
  }
}

// Conditional `return` inside a `try`, then a trailing fall-through value: the
// early-return routes through the epilogue (running the finally); the
// fall-through path runs the finally then yields the trailing value.
func condReturnThenValue(x: Int): Int {
  try {
    if x > 0 {
      return 5
    }
  } finally {
    ()
  }
  10
}

// Void (`Unit`) `return` inside a try/finally: exercises the `SReturn(None)`
// path where `retvalSlot` stays -1 and the epilogue emits `ret` with no load.
// The `finally` is observed via a List append (a reference type, so the
// mutation is visible to the caller).
func voidReturnInTry(log: in List[Int], x: in Int): Unit {
  try {
    if x > 0 {
      log.add(1)
      return
    }
    log.add(2)
  } finally {
    log.add(99)
  }
}

// `return` inside a try body that has BOTH a `catch` and a `finally`.
func returnInTryCatchFinally(log: in List[Int], x: in Int): Int {
  try {
    if x > 0 {
      return 5
    }
    return 6
  } catch Bug as _ {
    return 7
  } finally {
    log.add(42)
  }
}

// A normal (non-protected) return in the same function is unaffected.
func plainReturn(x: Int): Int {
  if x > 0 {
    return 100
  }
  200
}

test "return out of a try/finally runs the finally and yields the value" {
  assertEqualInt(returnThroughFinally(5), 10, "x>0 branch")
  assertEqualInt(returnThroughFinally(-1), 20, "x<=0 branch")
}

test "return out of a try/catch yields the value" {
  assertEqualInt(returnThroughCatch(5), 1, "x>0 branch")
  assertEqualInt(returnThroughCatch(-1), 2, "x<=0 branch")
}

test "return from inside a catch handler" {
  assertEqualInt(returnFromCatchBody(), 42, "catch-body return")
}

test "return out of nested try/finally propagates the inner value" {
  assertEqualInt(nestedFinally(), 7, "nested finally return")
}

test "conditional return in a try, then a trailing fall-through value" {
  assertEqualInt(condReturnThenValue(1), 5, "early return")
  assertEqualInt(condReturnThenValue(0), 10, "fall-through value")
}

test "void return inside a try/finally runs the finally" {
  val log1: List[Int] = newList()
  voidReturnInTry(log1, 5)
  // append 1, return, finally appends 99
  assertEqualInt(log1.count, 2, "early-return path: two entries")
  assertEqualInt(log1[0], 1, "early-return path: body entry")
  assertEqualInt(log1[1], 99, "early-return path: finally entry")
  val log2: List[Int] = newList()
  voidReturnInTry(log2, -1)
  // append 2, fall through, finally appends 99
  assertEqualInt(log2.count, 2, "fall-through path: two entries")
  assertEqualInt(log2[0], 2, "fall-through path: body entry")
  assertEqualInt(log2[1], 99, "fall-through path: finally entry")
}

test "return inside a try with both catch and finally" {
  val log: List[Int] = newList()
  assertEqualInt(returnInTryCatchFinally(log, 1), 5, "x>0 return value")
  assertEqualInt(log.count, 1, "finally ran exactly once")
  assertEqualInt(log[0], 42, "finally entry")
  val log2: List[Int] = newList()
  assertEqualInt(returnInTryCatchFinally(log2, 0), 6, "x<=0 return value")
  assertEqualInt(log2[0], 42, "finally ran on the second path too")
}

test "a plain return (no enclosing try) is unaffected" {
  assertEqualInt(plainReturn(1), 100, "x>0")
  assertEqualInt(plainReturn(0), 200, "fall-through")
}

// ── Impl-method epilogue path (lowerImplMethodMsil) ──────────────────────────
//
// `return`-in-try in a free function exercises `lowerFuncMsil`'s epilogue
// reservation; the parallel `lowerImplMethodMsil` path is wired identically
// but otherwise untested by this file.  An interface impl with a `return`
// inside a `try`/`finally` pins that second code path.
interface Compute {
  func step(x: in Int, log: in List[Int]): Int
}

record ComputeImpl {
}

impl Compute for ComputeImpl {
  func step(x: in Int, log: in List[Int]): Int {
    try {
      if x > 0 {
        return x * 2
      }
      return 0
    } finally {
      log.add(99)
    }
  }
}

test "return-in-try inside an impl method routes through the epilogue" {
  val c: Compute = ComputeImpl()
  val log1: List[Int] = newList()
  assertEqualInt(c.step(5, log1), 10, "x>0 returns x*2")
  assertEqualInt(log1.count, 1, "finally ran exactly once on early return")
  assertEqualInt(log1[0], 99, "finally marker on early return")
  val log2: List[Int] = newList()
  assertEqualInt(c.step(-3, log2), 0, "x<=0 returns 0")
  assertEqualInt(log2.count, 1, "finally ran exactly once on second return")
  assertEqualInt(log2[0], 99, "finally marker on second return")
}
