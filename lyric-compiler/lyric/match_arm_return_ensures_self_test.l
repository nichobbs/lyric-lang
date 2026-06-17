//! match_arm_return_ensures_self_test.l — #3842: InvalidProgramException when
//! every match-arm body exits via `return` in a function that carries
//! `ensures:` clauses.
//!
//! Before this fix the contract elaborator's `rewriteTrailingSExpr` naively
//! bound the trailing `match` expression to `let __lyric_result_<n> = <match>`
//! even when every arm `return`ed, leaving the `stloc` with no value on the
//! stack — the JIT rejected the method with `InvalidProgramException`.
//!
//! The fix deep-walks the trailing expression first (so nested `SReturn`s pick
//! up their own per-arm let/assert/return wrap) and skips the outer let-bind
//! whenever every path through the rewritten expression already exits.
//!
//! Run in CI via native `lyric test --target dotnet`.  Imports only `Std.*`.
@test_module
@runtime_checked
package Lyric.MatchArmReturnEnsuresSelfTest

import Std.Core
import Std.Testing

pub enum Color {
  case Red
  case Green
  case Blue
}

// Trailing `match` with `return` in every arm + ensures clause.
// Pre-fix: InvalidProgramException at the first call site.
pub func colorName(c: in Color): String
  ensures: result.length > 0
{
  match c {
    case Red -> return "red"
    case Green -> return "green"
    case Blue -> return "blue"
  }
}

// Trailing `if/else` where both branches `return`.
pub func sign(x: in Int): String
  ensures: result.length > 0
{
  if x >= 0 {
    return "non-negative"
  } else {
    return "negative"
  }
}

// Mixed: one arm returns, another yields a value.  The let-bind path is
// still needed when not every arm exits, so verify that case still works.
pub func describe(n: in Int): String
  ensures: result.length > 0
{
  match n {
    case 0 -> return "zero"
    case _ -> "non-zero"
  }
}

test "match arm with return in every arm under ensures: Red" {
  assertTrue(colorName(Red) == "red", "colorName(Red)")
}

test "match arm with return in every arm under ensures: Green" {
  assertTrue(colorName(Green) == "green", "colorName(Green)")
}

test "match arm with return in every arm under ensures: Blue" {
  assertTrue(colorName(Blue) == "blue", "colorName(Blue)")
}

test "if/else with return in both branches under ensures (positive)" {
  assertTrue(sign(5) == "non-negative", "sign(5)")
}

test "if/else with return in both branches under ensures (negative)" {
  assertTrue(sign(-3) == "negative", "sign(-3)")
}

test "match with mixed return/value arms under ensures: zero" {
  assertTrue(describe(0) == "zero", "describe(0)")
}

test "match with mixed return/value arms under ensures: non-zero" {
  assertTrue(describe(7) == "non-zero", "describe(7)")
}
