// minimal_return_test.l — Isolate return-union-in-if pattern.

@test_module
package Auth.MinimalReturnTest

import Std.Core
import Std.Testing

// Level 0: Direct construction — no if, no match
func alwaysErr(): Result[Unit, String] {
  Err("always")
}

// Level 0b: Direct construction — only Ok
func alwaysOk(): Result[Unit, String] {
  Ok(())
}

// Level 1: Single match on return value
func matchOnResult(r: in Result[Unit, String]): String {
  match r {
    case Ok(_)  -> "WAS_OK"
    case Err(e) -> e
  }
}

// Level 2: If-condition only (returns Bool, no union)
func ifReturns1(x: in Int): Bool {
  if x == 1 { return true }
  false
}

// Level 3: Return Err(String) from if
func returnErrStr(x: in Int): Result[Unit, String] {
  if x == 1 { return Err("one") }
  Ok(())
}

// Level 4: Return Err(Int) from if
func returnErrInt(x: in Int): Result[Unit, Int] {
  if x == 1 { return Err(42) }
  Ok(())
}

// Level 5: Return Some(Int) from if — compare with Err(Int)
func returnSomeInt(x: in Int): Option[Int] {
  if x == 1 { return Some(42) }
  None
}

// Level 6: Return Err(String) from match arm (not if)
func returnErrInMatch(x: in Int): Result[Unit, String] {
  match x {
    case 1 -> Err("one")
    case _ -> Ok(())
  }
}

test "L0: alwaysErr() direct Err construction" {
  val r = alwaysErr()
  val code = matchOnResult(r)
  assertEqual(code, "always", "direct Err must produce Err")
}

test "L0b: alwaysOk() direct Ok construction" {
  val r = alwaysOk()
  val code = matchOnResult(r)
  assertEqual(code, "WAS_OK", "direct Ok must produce Ok")
}

test "L1: matchOnResult on a direct Err literal" {
  val r: Result[Unit, String] = Err("literal")
  val code = matchOnResult(r)
  assertEqual(code, "literal", "local Err must match Err arm")
}

test "L2: ifReturns1 with x=1 must return true" {
  val b = ifReturns1(1)
  assertTrue(b, "ifReturns1(1) must be true")
}

test "L2b: ifReturns1 with x=2 must return false" {
  val b = ifReturns1(2)
  assertTrue(not b, "ifReturns1(2) must be false")
}

test "L3: return Err(String) from if fails?" {
  val r = returnErrStr(1)
  val code = matchOnResult(r)
  assertEqual(code, "one", "x=1 must return Err(one)")
}

test "L4: return Err(Int) from if fails?" {
  val r = returnErrInt(1)
  val isErr = match r { case Ok(_) -> false case Err(_) -> true }
  assertTrue(isErr, "x=1 must return Err(42)")
}

test "L5: return Some(Int) from if works?" {
  val r = returnSomeInt(1)
  val isSome = match r { case None -> false case Some(_) -> true }
  assertTrue(isSome, "x=1 must return Some(42)")
}

test "L6: return Err(String) from match arm works?" {
  val r = returnErrInMatch(1)
  val code = matchOnResult(r)
  assertEqual(code, "one", "x=1 must return Err(one) from match arm")
}
