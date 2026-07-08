//! enum_closure_pattern_bind_self_test.l — regression coverage for two
//! self-hosted MSIL backend bugs found and fixed in D-progress-623:
//!
//! - #5361: a payload-free `enum` with 2+ cases co-compiled with any
//!   closure literal crashed `Msil.Lowering` (`MNewobjByName could not
//!   resolve .ctor`) because `lowerMEnum` was the only type-lowering
//!   function that never called `recordUserTypeDefRow`, desyncing the
//!   positional `typeDefRowFqns` list every forward-referenced type
//!   (like a drained closure class) depends on.
//! - #5364: a `match`-arm-bound variable used directly as a call
//!   argument from inside its own arm crashed with
//!   `InvalidProgramException` when the scrutinee was a raw-value-typed
//!   "sentinel Option" (e.g. `.indexOf`'s `-1`-sentinel `Int`) — the
//!   pattern-bind fallback hardcoded the bound variable's slot type to
//!   `MObject` regardless of the real scrutinee type, leaving an
//!   unboxed `int32` in an object-declared local.
//!
//! Run via native `lyric test` (imports only `Std.*`, no
//! `LYRIC_LOAD_COMPILER=1` needed), mirroring `bitwise_self_test.l`.
@test_module
package Lyric.EnumClosurePatternBindSelfTest

import Std.Core
import Std.String
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// #5361 — payload-free enum + closure in the same compile unit
// ─────────────────────────────────────────────────────────────────────────────
pub enum TrafficLight {
  case Red
  case Yellow
  case Green
}

alias IntHandler = (Int) -> Int

func makeAdder(n: in Int): IntHandler {
  return { x: Int -> x + n }
}

test "payload-free enum co-compiled with a closure does not crash lowering" {
  val h = makeAdder(5)
  assertEqualInt(h(10), 15, "closure captures n=5 correctly alongside a payload-free enum")
}

// ─────────────────────────────────────────────────────────────────────────────
// #5364 — match-arm-bound variable used directly as a call argument
// ─────────────────────────────────────────────────────────────────────────────
func parseQueryPair(pair: in String): Option[String] {
  match pair.indexOf("=") {
    case Some(eq) -> {
      // `eq` used directly as a call argument from inside its own arm —
      // this is exactly the shape that crashed with InvalidProgramException.
      val key = pair.substring(0, eq)
      Some(key)
    }
    case None -> None
  }
}

test "match-arm-bound variable used directly as a substring call argument" {
  match parseQueryPair("q=hello") {
    case Some(key) -> assertEqual(key, "q", "bound `eq` used directly in substring(0, eq)")
    case None -> assertTrue(false, "expected Some")
  }
}

test "match-arm-bound variable from lastIndexOf used directly as a call argument" {
  match "a.b.c".lastIndexOf(".") {
    case Some(lastDot) -> {
      val ext = "a.b.c".substring(lastDot)
      assertEqual(ext, ".c", "bound `lastDot` used directly in substring(lastDot)")
    }
    case None -> assertTrue(false, "expected Some")
  }
}
