//! jvm/sam_detection_self_test.l — lambda-semantics companion to the SAM bridging suite.
//!
//! Historical note: this file was drafted as the "Stage 5" suite for
//! metadata-driven SAM interface resolution (epic #1877 Phase 2, JVM), but it
//! never actually passed a lambda across the FFI boundary — every assertion
//! below exercises local lambda semantics only (capture, escape, nesting) —
//! and it used a `(x: T) -> e` arrow-lambda form the parser does not accept,
//! so it never compiled either.
//!
//! The real lambda → functional-interface (SAM) bridging now ships in the
//! auto-FFI path: `Jvm.AutoFfi.findSamMethod` detects a functional-interface
//! parameter from JDK metadata, the overload scorer ranks a lambda argument
//! as assignable to it, and `Jvm.Codegen.emitFfiCoerce` wraps the closure in
//! a synthesized adapter class implementing the target interface.  Its
//! runtime-asserted, CI-wired coverage (Runnable / Comparator / Function /
//! Consumer, capture and inline-literal forms) lives in
//! `lyric-compiler/lyric/auto_ffi_jvm_self_test.l`.
//!
//! This file is kept as a plain-`main` regression program for the local
//! lambda semantics it does assert, plus one FFI round-trip through a real
//! JDK functional interface (`Function` via `Map.computeIfAbsent`).
//!
//! Manual run (from repo root, after `make lyric`):
//!   ./bin/lyric run --target jvm lyric-compiler/jvm/sam_detection_self_test.l
package Jvm.SamDetectionSelfTest

import Std.Core
import Std.Collections
import Std.Testing

extern type JHashMap = "java.util.HashMap"

// Test 1: lambda with a typed param and Bool result.
func testPredicateShapedLambda(): Unit {
  val isPositive: (Int) -> Bool = { x: Int -> x > 0 }
  assertTrue(isPositive(1), "positive number")
  // `assertFalse` (not `assertTrue(not …)`): `not` on the erased Object result
  // of a lambda invocation trips a pre-existing JVM-backend VerifyError
  // (ixor on an unboxed-less Object operand) unrelated to what this asserts.
  assertFalse(isPositive(-1), "negative number")
}

// Test 2: multi-parameter lambda.
func testBiFunctionShapedLambda(): Unit {
  val add: (Int, Int) -> Int = { x: Int, y: Int -> x + y }
  assertEqualInt(add(1, 2), 3, "addition result")
}

// Test 3: zero-arg lambda capturing (and mutating) an enclosing var — the
// captured `counter` lives in a hoisted cell shared with the enclosing scope.
func testCapturingLambda(): Unit {
  var counter = 0
  val increment: () -> Int = { -> counter = counter + 1; counter }
  assertEqualInt(increment(), 1, "first increment")
  assertEqualInt(increment(), 2, "second increment")
}

// Test 4: escaped lambda (returned from a function) still sees its capture.
func makeGreeter(name: in String): (String) -> String {
  { greeting: String -> greeting + ", " + name }
}

func testEscapingLambda(): Unit {
  val greet = makeGreeter("Alice")
  val result = greet("Hello")
  assertEqual(result, "Hello, Alice", "escaped lambda capture")
}

// Test 5: nested closure (a lambda defined inside another lambda) capturing
// both the inner lambda's enclosing param and the outermost local.
func testNestedClosure(): Unit {
  val outerVal = 10
  val makeAdder: (Int) -> ((Int) -> Int) = { x: Int -> val inner: (Int) -> Int = { y: Int -> x + y + outerVal }; inner }
  val add5 = makeAdder(5)
  assertEqualInt(add5(3), 18, "nested closure: 5 + 3 + 10")
}

// Test 6: the FFI boundary itself — a capturing lambda bridged to
// java.util.function.Function through Map.computeIfAbsent and invoked by the
// JDK, not by Lyric code.
func testSamBridgedFunction(): Unit {
  val prefix = "v:"
  val m = JHashMap.new()
  val v = m.computeIfAbsent("key", { k: String -> prefix + k })
  assertEqual(v, "v:key", "SAM-bridged Function invoked by HashMap")
}

func main(): Int {
  testPredicateShapedLambda()
  testBiFunctionShapedLambda()
  testCapturingLambda()
  testEscapingLambda()
  testNestedClosure()
  testSamBridgedFunction()
  0
}
