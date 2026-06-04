// book_ch02_tests.l — Chapter 2: Core Types
//
// Verifies: primitive types, range subtypes (tryFrom), numeric literals,
// boolean logic, and Never-returning functions.
package Book.Ch02.Tests

import Std.Core
import Std.Testing

// ---------------------------------------------------------------------------
// §2.1 Primitive types
// ---------------------------------------------------------------------------

func testPrimitives(): Unit {
  val b: Bool   = true
  val i: Int    = -2_147_483_648
  val l: Long   = 9_000_000_000_000_000_000i64
  val d: Double = 3.14
  val s: String = "hello"
  val c: Char   = 'A'

  assertTrue(b, "Bool true")
  assertEqualInt(i, -2_147_483_648, "Int min value")
  assertTrue(l > 0i64, "Long positive")
  assertTrue(d > 3.0, "Double gt 3.0")
  assertEqual(s, "hello", "String literal")
  assertTrue(c == 'A', "Char literal")
}

func testNumericLiterals(): Unit {
  assertEqualInt(0xFF, 255, "hex literal")
  assertEqualInt(0b1010, 10, "binary literal")
  assertEqualInt(0o755, 493, "octal literal")
  assertEqualInt(1_000_000, 1000000, "underscore separator")
}

func testBoolLogic(): Unit {
  assertTrue(true and true, "and")
  assertTrue(not (true and false), "and false")
  assertTrue(true or false, "or")
  assertTrue(not (false or false), "or false")
  assertTrue(true xor false, "xor")
  assertTrue(not (true xor true), "xor same")
}

// ---------------------------------------------------------------------------
// §2.2 Range subtypes
// ---------------------------------------------------------------------------

type Age = Int range 0 ..= 150
type DiceRoll = Int range 1 ..= 6

func testRangeSubtypeOk(): Unit {
  val a = Age.tryFrom(25)
  assertTrue(isOk(a), "Age.tryFrom 25 is Ok")
  assertEqualInt(unwrapResult(a).toInt(), 25, "Age value round-trips")

  val d = DiceRoll.tryFrom(6)
  assertTrue(isOk(d), "DiceRoll.tryFrom 6 is Ok")
  assertEqualInt(unwrapResult(d).toInt(), 6, "DiceRoll max value")
}

func testRangeSubtypeErr(): Unit {
  val tooOld = Age.tryFrom(200)
  assertTrue(isErr(tooOld), "Age.tryFrom 200 is Err")

  val zero = DiceRoll.tryFrom(0)
  assertTrue(isErr(zero), "DiceRoll.tryFrom 0 is Err")

  val neg = Age.tryFrom(-1)
  assertTrue(isErr(neg), "Age.tryFrom -1 is Err")
}

func main(): Unit {
  testPrimitives()
  testNumericLiterals()
  testBoolLogic()
  testRangeSubtypeOk()
  testRangeSubtypeErr()
  println("book_ch02: ok")
}
