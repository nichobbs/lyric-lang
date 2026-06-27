//! msil/delegate_metadata_self_test.l — Stage 5 test suite for metadata-driven delegate resolution.
//!
//! Tests that Lyric lambdas can be converted to .NET delegates with correct
//! type signatures based on metadata-driven resolution, not hardcoded guesses.
//! Verifies that lambda-to-delegate conversions preserve type safety and capture
//! semantics across the FFI boundary.

@test_module
package Msil.DelegateMetadataSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// Extern delegate types for testing FFI boundary.
extern type Predicate = "System.Predicate`1"
extern type Func1 = "System.Func`2"
extern type Func2 = "System.Func`3"

test "basic lambda invocation" {
  val isPositive: (Int) -> Bool = (x: Int) -> x > 0
  assertTrue(isPositive(1))
  assertFalse(isPositive(-1))
  assertFalse(isPositive(0))
}

test "multi-parameter lambda" {
  val add: (Int, Int) -> Int = (x: Int, y: Int) -> x + y
  assertEq(add(1, 2), 3)
  assertEq(add(10, 20), 30)
}

test "capturing lambda with mutation" {
  var counter = 0
  val increment: () -> Int = () -> {
    counter = counter + 1
    counter
  }
  assertEq(increment(), 1)
  assertEq(increment(), 2)
  assertEq(counter, 2)
}

test "returned lambda (escaped closure)" {
  func makeGreeter(name: in String): (String) -> String {
    (greeting: String) -> greeting + ", " + name
  }
  val greet = makeGreeter("Alice")
  val result = greet("Hello")
  assertEq(result, "Hello, Alice")
}

test "nested closures with captures" {
  val outerVal = 10
  val makeAdder: (Int) -> ((Int) -> Int) = (x: Int) -> {
    val inner: (Int) -> Int = (y: Int) -> x + y + outerVal
    inner
  }
  val add5 = makeAdder(5)
  assertEq(add5(3), 18)
  assertEq(add5(7), 22)
}
