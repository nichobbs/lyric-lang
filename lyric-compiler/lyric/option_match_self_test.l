@test_module
package TestOptionMatch

import Std.Core
import Std.Testing

// Test Option[String] — reference-type type argument (#1550)
union Container {
  case WithOpt(value: Option[String])
}

func testIt(c: Container): Int {
  match c {
    case WithOpt(o) -> match o { case Some(_) -> 1; case None -> 2 }
  }
}

test "matches Some correctly" {
  assertEqualInt(testIt(WithOpt(value = Some(value = "hello"))), 1, "matches Some correctly")
}

test "matches None correctly" {
  assertEqualInt(testIt(WithOpt(value = None)), 2, "matches None correctly")
}

// Test Option[Int] — value-type type argument (#1550)
union IntContainer {
  case WithIntOpt(value: Option[Int])
}

func testIntIt(c: IntContainer): Int {
  match c {
    case WithIntOpt(o) -> match o { case Some(v) -> v; case None -> 0 }
  }
}

test "matches Some[Int] correctly" {
  assertEqualInt(testIntIt(WithIntOpt(value = Some(value = 42))), 42, "matches Some[Int] correctly")
}

test "matches None from Int correctly" {
  assertEqualInt(testIntIt(WithIntOpt(value = None)), 0, "matches None from Int correctly")
}

// Test nested Result[Option[String], String] (#1550)
union ResultContainer {
  case WithResultOpt(value: Result[Option[String], String])
}

func testResultIt(c: ResultContainer): Int {
  match c {
    case WithResultOpt(r) -> match r { case Ok(o) -> match o { case Some(_) -> 1; case None -> 2 }; case Err(_) -> 0 }
  }
}

test "matches Ok(Some) correctly" {
  assertEqualInt(testResultIt(WithResultOpt(value = Ok(value = Some(value = "x")))), 1, "matches Ok(Some) correctly")
}

test "matches Ok(None) correctly" {
  assertEqualInt(testResultIt(WithResultOpt(value = Ok(value = None))), 2, "matches Ok(None) correctly")
}

test "matches Err correctly" {
  assertEqualInt(testResultIt(WithResultOpt(value = Err(error = "oops"))), 0, "matches Err correctly")
}

// Test binding alias — case Some(x) binding instead of Some(_) (#1550)
union AliasContainer {
  case WithAliasOpt(value: Option[String])
}

func testAliasIt(c: AliasContainer): String {
  match c {
    case WithAliasOpt(o) -> match o { case Some(x) -> x; case None -> "none" }
  }
}

test "binding alias extracts value correctly" {
  assertEqual(
    testAliasIt(WithAliasOpt(value = Some(value = "extracted"))),
    "extracted",
    "binding alias extracts value correctly"
  )
}

test "binding alias handles None correctly" {
  assertEqual(testAliasIt(WithAliasOpt(value = None)), "none", "binding alias handles None correctly")
}
