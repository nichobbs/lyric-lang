//! An unannotated binding of an `if` or `match` whose branches build a value
//! of a generic union with different evidence: `val r = match o { case
//! Some(x) -> x; case None -> Ok(value = 1) }`, where `Ok(...)` fixes `T`
//! but not `E`.  The type checker knows the binding's type
//! (`Result[Int, String]`, from the other branch); it now records it as the
//! binding's annotation, so every branch is built at it.  Before, MSIL built
//! the `Ok` branch as `Result_Ok<int, object>`: unverifiable IL
//! (StackUnexpected at the join), and a later `match` on the value never
//! recognised it ("match not exhaustive").  The JVM erases generics and was
//! unaffected; both targets run every case.
@test_module
package BranchBindingCtorTypeSelfTest

import Std.Core
import Std.Testing

union Shape {
  case Dot(n: Int)
  case Pair(a: Shape, b: Shape)
}

func resValue(r: in Result[Int, String]): Int {
  match r {
    case Ok(v) -> v
    case Err(e) -> e.length * 100
  }
}

func fromOption(o: in Option[Result[Int, String]], d: in Int): Int {
  val r = match o { case Some(x) -> x; case None -> Ok(value = d) }
  resValue(r)
}

func fromOptionErrSecond(o: in Option[Result[Int, String]]): Int {
  val r = match o { case Some(x) -> x; case None -> Err(error = "none") }
  resValue(r)
}

func fromFlag(c: in Bool, r0: in Result[Int, String]): Int {
  val r = if c { r0 } else { Ok(value = 7) }
  resValue(r)
}

func varBinding(c: in Bool, r0: in Result[Int, String]): Int {
  var r = if c { r0 } else { Err(error = "ab") }
  resValue(r)
}

func userPayload(o: in Option[Result[Shape, String]]): Int {
  val r = match o { case Some(x) -> x; case None -> Ok(value = Dot(n = 4)) }
  match r {
    case Ok(s) -> match s { case Dot(n) -> n; case Pair(_, _) -> -1 }
    case Err(_) -> -2
  }
}

func optionBranch(c: in Bool, o0: in Option[Int]): Int {
  val o = if c { o0 } else { Some(value = 9) }
  match o {
    case Some(v) -> v
    case None -> -1
  }
}

test "an Ok branch takes the binding's error type" {
  assertEqualInt(fromOption(None, 3), 3, "Ok branch")
  assertEqualInt(fromOption(Some(value = Ok(value = 5)), 3), 5, "Some branch")
  assertEqualInt(fromOption(Some(value = Err(error = "xy")), 3), 200, "Some(Err) branch")
}

test "an Err branch takes the binding's value type" {
  assertEqualInt(fromOptionErrSecond(None), 400, "Err branch")
  assertEqualInt(fromOptionErrSecond(Some(value = Ok(value = 6))), 6, "Some branch")
}

test "an if expression's branches are built at the binding's type" {
  assertEqualInt(fromFlag(false, Err(error = "q")), 7, "Ok branch")
  assertEqualInt(fromFlag(true, Err(error = "q")), 100, "given branch")
  assertEqualInt(varBinding(false, Ok(value = 1)), 200, "var, Err branch")
  assertEqualInt(varBinding(true, Ok(value = 1)), 1, "var, given branch")
}

test "a payload of a union declared here" {
  assertEqualInt(userPayload(None), 4, "Ok branch")
  assertEqualInt(userPayload(Some(value = Err(error = "e"))), -2, "Some(Err) branch")
}

test "an Option branch" {
  assertEqualInt(optionBranch(false, None), 9, "Some branch")
  assertEqualInt(optionBranch(true, None), -1, "given None")
}
