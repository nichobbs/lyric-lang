//! try_catch_expr_self_test.l — regression tests for `try { … } catch … { … }`
//! used as a value-producing expression on the self-hosted MSIL target (#1823;
//! epic #1470, Band 2).
//!
//! A `try`/`catch` whose result is consumed (a function's trailing value, a `val`
//! initializer, a sub-expression) previously lowered as a discarded statement, so
//! the branch values never reached the stack and a non-void function emitted a
//! bare `ret` with nothing to return — unverifiable IL (`InvalidProgramException`
//! at JIT time).  Codegen now lowers a trailing `try`/`catch` as a value: each
//! branch (try body + every catch handler) is stashed into a shared temp before
//! its `leave` and reloaded after the merge label.
//!
//! Run via native `lyric test --target dotnet`.  Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/try_catch_expr_self_test.l
//!
//! MSIL target only; JVM parity is tracked under epic #1470's JVM-deferral note.
@test_module
package Lyric.TryCatchExprSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// Fall-through value vs caught value (the #1823 minimal repro shape).
func classify(x: Int): Int {
  try {
    if x > 0 {
      panic("positive")
    }
    0
  } catch Bug as _ {
    -1
  }
}

// The catch handler binds the exception and derives the value from its message.
func messageLen(): Int {
  try {
    panic("abcde")
    0
  } catch Bug as b {
    b.message.length
  }
}

// try/catch expression with a finally that runs for its side effect; the branch
// value is still returned.
func withFinally(log: in List[Int], x: Int): Int {
  try {
    if x > 0 {
      panic("x")
    }
    7
  } catch Bug as _ {
    9
  } finally {
    log.add(1)
  }
}

// The `assertPanics` shape: a try/catch expression yielding a Bool.
func didPanic(shouldPanic: Bool): Bool {
  try {
    if shouldPanic {
      panic("boom")
    }
    false
  } catch Bug as _ {
    true
  }
}

// try/catch expression as a `val` initializer (value consumed mid-function).
func viaLocal(x: Int): Int {
  val r = try {
    if x > 0 {
      panic("p")
    }
    100
  } catch Bug as _ {
    200
  }
  r + 1
}

test "try/catch expression yields the fall-through value" {
  assertEqualInt(classify(0), 0, "no panic -> try-body value")
  assertEqualInt(classify(5), -1, "panic -> catch value")
}

test "catch handler can use the bound exception to produce the value" {
  // The caught Bug's message is the panic argument "abcde" (length 5); the
  // point is that the bound `b` is usable to compute the expression's value.
  assertEqualInt(messageLen(), 5, "message length from caught Bug")
}

test "try/catch expression with a finally returns the branch value" {
  val log1: List[Int] = newList()
  assertEqualInt(withFinally(log1, 0), 7, "try-body value")
  assertEqualInt(log1.count, 1, "finally ran on the success path")
  val log2: List[Int] = newList()
  assertEqualInt(withFinally(log2, 5), 9, "catch value")
  assertEqualInt(log2.count, 1, "finally ran on the catch path")
}

test "try/catch expression yields a Bool (assertPanics shape)" {
  assertTrue(didPanic(true), "panicking thunk -> true")
  assertTrue(not didPanic(false), "non-panicking thunk -> false")
}

test "try/catch expression as a val initializer" {
  assertEqualInt(viaLocal(0), 101, "try-body value + 1")
  assertEqualInt(viaLocal(5), 201, "catch value + 1")
}

// Nested `try`/`catch` expression — both layers are value-producing and the
// inner expression is the outer try body.  Exercises the interaction between
// two `tryRegionStack` push/pop cycles and ensures the outer resultSlot
// receives the inner expression's stashed value.
func nested(innerPanic: Bool, outerPanic: Bool): Int {
  try {
    val inner = try {
      if innerPanic {
        panic("i")
      }
      1
    } catch Bug as _ {
      2
    }
    if outerPanic {
      panic("o")
    }
    inner
  } catch Bug as _ {
    3
  }
}

test "nested try/catch expression: each layer yields the right branch value" {
  // No panic anywhere: outer try-body returns the inner try-body value (1).
  assertEqualInt(nested(false, false), 1, "no panic -> inner try value")
  // Inner panics, outer doesn't: inner's catch -> 2; outer propagates 2.
  assertEqualInt(nested(true, false), 2, "inner panic -> inner catch value")
  // Outer panics after the inner runs: outer's catch -> 3.
  assertEqualInt(nested(false, true), 3, "outer panic -> outer catch value")
  // Both panic: inner's catch swallows the inner panic (2 propagates upward),
  // outer panic then fires its own catch -> 3.
  assertEqualInt(nested(true, true), 3, "both panic -> outer catch value")
}

// A panic originating inside the inner catch block — a distinct path from any of
// the four `nested` cases above.  When the inner catch itself panics, the outer
// try region is still active and must intercept the exception.
func innerCatchPanics(): Int {
  try {
    try {
      panic("i")
      1
    } catch Bug as _ {
      panic("ic")
      2
    }
    10
  } catch Bug as _ {
    3
  }
}

test "inner catch panic is intercepted by the outer try region" {
  assertEqualInt(innerCatchPanics(), 3, "inner-catch panic -> outer catch yields 3")
}
