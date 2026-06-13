//! try_catch_expr_jvm_self_test.l — JVM try/catch-as-expression regression test
//! (#3193, epic #2663).
//!
//! `lowerTryCatchExpr` (jvm/codegen/05_stmts.l) routes the try body's value and
//! each catch arm's value through a single result slot so the operand stack is
//! empty at the join label.  Two properties matter and are pinned here:
//!
//!   - When every arm yields a value of the try-body type, the result slot is
//!     stored and loaded correctly: the normal (no-throw) path yields the try
//!     body's value and the throwing path yields the catch arm's value.  This
//!     is the regression guard for the #3193 change, which only narrows the
//!     value-less-catch-arm abort path and must leave valid cases untouched.
//!   - A catch arm that yields Unit while the try body yields a value is the
//!     documented type-checker gap #2042.  The JVM backend cannot route an
//!     absent value through the result slot, so it now aborts codegen with a
//!     source-located `error[J004]` diagnostic (replacing the unlocated panic
//!     from #2690) rather than emitting an unverifiable class.  That error path
//!     aborts compilation, so it is verified manually with
//!     `lyric build --target jvm` (see the issue / PR) rather than asserted at
//!     runtime here.
//!
//! Run by native `lyric test --target jvm`, which compiles this module in-process
//! through the self-hosted `Jvm.Bridge` (`compileToJarBundled`) and runs it under
//! `java`.  Imports only `Std.*`.
@test_module
package Jvm.TryCatchExprSelfTest

import Std.Core
import Std.Testing

// try/catch in expression position where BOTH arms yield an Int.  The trailing
// `r` is the function's value, so the try-catch expression's result slot must be
// loaded on every path.
func computeInt(n: Int): Int {
  val r = try {
    if n < 0 {
      panic("negative")
    }
    n * 2
  } catch Bug as _ {
    -1
  }
  r
}

// Same shape, String-valued, to pin the `astore`/`aload` result-slot variant
// (the Int case pins `istore`/`iload`).
func computeStr(n: Int): String {
  val r = try {
    if n == 0 {
      panic("zero")
    }
    "ok"
  } catch Bug as _ {
    "caught"
  }
  r
}

// The catch arm binds the exception and still yields a value: pins that the
// bind-name slot allocation does not disturb the result-slot routing.
func computeBound(n: Int): Int {
  val r = try {
    if n > 100 {
      panic("too big")
    }
    n + 1
  } catch Bug as e {
    0
  }
  r
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "try-catch expression: Int arms, no-throw path yields try-body value" {
  assertEqualInt(computeInt(5), 10, "5 * 2 = 10 (try body)")
  assertEqualInt(computeInt(21), 42, "21 * 2 = 42 (try body)")
}

test "try-catch expression: Int arms, throwing path yields catch-arm value" {
  assertEqualInt(computeInt(-1), -1, "negative -> caught -> -1 (catch arm)")
}

test "try-catch expression: String arms route through the aload result slot" {
  assertEqual(computeStr(3), "ok", "non-zero -> try body 'ok'")
  assertEqual(computeStr(0), "caught", "zero -> panic -> catch 'caught'")
}

test "try-catch expression: bound exception arm still yields a value" {
  assertEqualInt(computeBound(4), 5, "4 + 1 = 5 (try body)")
  assertEqualInt(computeBound(200), 0, "200 > 100 -> panic -> catch 0")
}
