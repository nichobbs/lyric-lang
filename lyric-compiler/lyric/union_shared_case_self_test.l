//! union_shared_case_self_test.l - two unions of one package sharing a case name build the
//! case of the union the checker resolved on every target (#8481).
//!
//! The checker resolves a bare case constructor (`Both(n = 2)`) against the expected
//! type, but the JVM and native backends looked the name up in a package-wide table that holds
//! the first (native) or last (JVM) union declaring it, so a `return Both(n = 2)` in a function
//! returning the other union built the wrong case: a `ClassCastException` on the JVM and
//! `N0007` on native.  The expected type now picks the case.  The cases cover a `return`, a
//! tail expression, a call argument and a typed binding, with either union declared last.
@test_module
package Lyric.UnionSharedCaseSelfTest

import Std.Core
import Std.Testing

union Left {
  case Both(n: Int)
  case OnlyLeft
  case Idle
}

union Right {
  case Both(n: Int)
  case OnlyRight
  case Idle
}

func leftBoth(): Left {
  Both(n = 1)
}

func rightBoth(c: in Bool): Right {
  if c {
    return Both(n = 2)
  }
  OnlyRight
}

func leftValue(l: in Left): Int {
  match l {
    case Both(n) -> n
    case OnlyLeft -> 100
    case Idle -> 101
  }
}

func rightValue(r: in Right): Int {
  match r {
    case Both(n) -> n * 10
    case OnlyRight -> 1000
    case Idle -> 1001
  }
}

test "a tail expression builds the declared return type's case" {
  assertEqualInt(leftValue(leftBoth()), 1, "Left.Both")
}

test "a return in an if builds the declared return type's case" {
  assertEqualInt(rightValue(rightBoth(true)), 20, "Right.Both")
  assertEqualInt(rightValue(rightBoth(false)), 1000, "Right.OnlyRight")
}

test "a call argument builds the parameter type's case" {
  assertEqualInt(leftValue(Both(n = 7)), 7, "Left.Both argument")
  assertEqualInt(rightValue(Both(n = 7)), 70, "Right.Both argument")
}

test "a binding with a declared type builds that type's case" {
  val r: Right = Both(n = 3)
  val l: Left = Both(n = 4)
  assertEqualInt(rightValue(r), 30, "val Right")
  assertEqualInt(leftValue(l), 4, "val Left")
}

func leftIdle(c: in Bool): Left {
  if c {
    return Idle
  }
  OnlyLeft
}

func rightIdle(): Right {
  Idle
}

test "a bare nullary case in a return builds the declared return type's case (#8649)" {
  assertEqualInt(leftValue(leftIdle(true)), 101, "Left.Idle")
  assertEqualInt(leftValue(leftIdle(false)), 100, "Left.OnlyLeft")
}

test "a bare nullary case as a tail expression builds the declared return type's case (#8649)" {
  assertEqualInt(rightValue(rightIdle()), 1001, "Right.Idle")
}

test "a bare nullary case argument builds the parameter type's case (#8649)" {
  assertEqualInt(leftValue(Idle), 101, "Left.Idle argument")
  assertEqualInt(rightValue(Idle), 1001, "Right.Idle argument")
}

test "a bare nullary case in a typed binding builds that type's case (#8649)" {
  val l: Left = Idle
  val r: Right = Idle
  assertEqualInt(leftValue(l), 101, "val Left")
  assertEqualInt(rightValue(r), 1001, "val Right")
}
