//! nested_nullary_pattern_native_self_test.l - a nullary union case nested in a constructor
//! pattern (`case Ok(Back) ->`) tests the case on `--target native`.
//!
//! The native backend bound every bare identifier inside a constructor pattern, so `Ok(Back)`
//! was `Ok(_)` with a binding named `Back` and matched whichever `Ok` no earlier arm took: a
//! `Toast` message was handled as `Back`.  The identifier is now a case test when the field's
//! type is a union that has a case of that name.  A real binding of the same shape (a name that
//! is no case of the field's union) still binds.
@test_module
package Lyric.NestedNullaryPatternNativeSelfTest

import Std.Core
import Std.Testing

union Msg {
  case Patch(v: Int)
  case Nav(u: String)
  case Back
  case Toast(m: String)
  case Idle
}

func decode(k: Int): Result[Msg, String] {
  if k == 0 {
    return Ok(value = Patch(v = 1))
  }
  if k == 1 {
    return Ok(value = Nav(u = "x"))
  }
  if k == 2 {
    return Ok(value = Back)
  }
  if k == 3 {
    return Ok(value = Toast(m = "hi"))
  }
  if k == 4 {
    return Ok(value = Idle)
  }
  Err(error = "bad")
}

func name(k: Int): String {
  match decode(k) {
    case Err(e) -> "err"
    case Ok(Patch(v)) -> "patch"
    case Ok(Nav(u)) -> "nav"
    case Ok(Back) -> "back"
    case Ok(Toast(m)) -> "toast"
    case Ok(Idle) -> "idle"
  }
}

func wrapped(k: Int): String {
  match decode(k) {
    case Err(_) -> "err"
    case Ok(Back) -> "back"
    case Ok(other) -> "other"
  }
}

func optional(k: Int): Int {
  val m: Option[Msg] = if k == 0 { Some(value = Back) } else if k == 1 { Some(value = Idle) } else { None }
  match m {
    case Some(Back) -> 10
    case Some(Idle) -> 20
    case Some(_) -> 30
    case None -> 40
  }
}

test "every arm of a nested nullary match takes its own case" {
  assertEqual(name(0), "patch", "patch")
  assertEqual(name(1), "nav", "nav")
  assertEqual(name(2), "back", "back")
  assertEqual(name(3), "toast", "toast is not back")
  assertEqual(name(4), "idle", "idle is not back")
  assertEqual(name(5), "err", "err")
}

test "a nested nullary arm followed by a binding falls through for the other cases" {
  assertEqual(wrapped(2), "back", "back")
  assertEqual(wrapped(3), "other", "toast")
  assertEqual(wrapped(0), "other", "patch")
}

test "the same holds under Option" {
  assertEqualInt(optional(0), 10, "Some(Back)")
  assertEqualInt(optional(1), 20, "Some(Idle)")
  assertEqualInt(optional(2), 40, "None")
}
