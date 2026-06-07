//! book_ch01_tests.l — Chapter 1: Getting Started
//!
//! Verifies the hello-world fundamentals shown in chapter 1: package
//! declarations, println, string interpolation, and basic variable bindings.
//!
//! Book chapter test coverage status (as of 2026-06-07):
//!   Covered:  ch01, ch02, ch03, ch04, ch05, ch07, ch12, ch13-ffi
//!   Deferred: ch06 (Interfaces — requires interface dispatch; blocked on #2580)
//!             ch08 (Async — requires async/await harness; blocked on #2580)
//!             ch09 (Opaque Types — requires opaque-type construction; blocked on #2580)
//!             ch10 (Protected Types — requires protected-type monitor; blocked on #2580)
//!             ch11 (Dependency Injection — requires wire blocks; blocked on #2580)
//!             ch14 (Contracts — requires @proof_required + SMT harness; blocked on #2580)
//!             ch15 (Aspects — requires aspect weaving; blocked on #2580)
//!             ch16 (Mocking and Test Wires — requires wire + mock infrastructure; blocked on #2580)
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
  // Bool toString uses .NET's Boolean.ToString() which capitalises: "True"/"False".
  // This is a known stage-0 bootstrap emitter behaviour; tracked in issue #2225.
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
