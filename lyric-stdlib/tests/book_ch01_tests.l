// book_ch01_tests.l — Chapter 1: Getting Started
//
// Verifies the hello-world fundamentals shown in chapter 1: package
// declarations, println, string interpolation, and basic variable bindings.
package Book.Ch01.Tests

import Std.Core
import Std.Testing

func testHelloWorldBuiltins(): Unit {
  // println is a builtin that takes a String; just verify it doesn't panic
  println("Hello, world!")
  assertTrue(true, "println completed without panic")
}

func testStringInterpolation(): Unit {
  val name = "world"
  val msg = "Hello, ${name}!"
  assertEqual(msg, "Hello, world!", "string interpolation with val")

  val n = 42
  assertEqual("n = ${toString(n)}", "n = 42", "interpolation with toString")
}

func testVariableBindings(): Unit {
  val x = 42
  assertEqualInt(x, 42, "val binding immutable")

  var y = 0
  y = 10
  assertEqualInt(y, 10, "var binding mutable")
  y += 5
  assertEqualInt(y, 15, "var compound assignment")
}

func doNothing(): Unit {
  // no return statement needed
}

func testUnitReturn(): Unit {
  doNothing()
  assertTrue(true, "Unit-returning function completes without return")
}

func testToString(): Unit {
  assertEqual(toString(42), "42", "toString Int")
  assertEqual(toString(true), "True", "toString Bool")
  assertEqual(toString(3.14), "3.14", "toString Double")
}

func main(): Unit {
  testHelloWorldBuiltins()
  testStringInterpolation()
  testVariableBindings()
  testUnitReturn()
  testToString()
  println("book_ch01: ok")
}
