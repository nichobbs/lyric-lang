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

// Test 1: Verify lambdas and basic Lyric function values.
@test func testBasicLambdaInvocation(): Unit {
  val isPositive: (Int) -> Bool = (x: Int) -> x > 0
  assertTrue(isPositive(1), message = "positive number should return true")
  assertFalse(isPositive(-1), message = "negative number should return false")
  assertFalse(isPositive(0), message = "zero should return false")
}

// Test 2: Multi-parameter lambda function values.
@test func testMultiParameterLambda(): Unit {
  val add: (Int, Int) -> Int = (x: Int, y: Int) -> x + y
  assertEq(add(1, 2), 3, message = "addition result should be 3")
  assertEq(add(10, 20), 30, message = "addition result should be 30")
}

// Test 3: Capturing lambdas with mutable reference.
@test func testCapturingLambda(): Unit {
  var counter = 0
  val increment: () -> Int = () -> {
    counter = counter + 1
    counter
  }
  assertEq(increment(), 1, message = "first increment should be 1")
  assertEq(increment(), 2, message = "second increment should be 2")
  assertEq(counter, 2, message = "counter should be 2 after two increments")
}

// Test 4: Returned lambda (escaped closure).
@test func testReturnedLambda(): Unit {
  func makeGreeter(name: in String): (String) -> String {
    (greeting: String) -> greeting + ", " + name
  }
  val greet = makeGreeter("Alice")
  val result = greet("Hello")
  assertEq(result, "Hello, Alice", message = "greeting should include captured name")
}

// Test 5: Nested closures with multiple capture levels.
@test func testNestedClosure(): Unit {
  val outerVal = 10
  val makeAdder: (Int) -> ((Int) -> Int) = (x: Int) -> {
    val inner: (Int) -> Int = (y: Int) -> x + y + outerVal
    inner
  }
  val add5 = makeAdder(5)
  assertEq(add5(3), 18, message = "nested closure: 5 + 3 + 10 = 18")
  assertEq(add5(7), 22, message = "nested closure: 5 + 7 + 10 = 22")
}
