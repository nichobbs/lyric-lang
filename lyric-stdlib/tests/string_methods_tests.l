// stdlib/tests/string_methods_tests.l — Tests for method-syntax string ops.
//
// `string_tests.l` covers the free-function forms (`substring(s, ..)`);
// this file covers the UFCS/method-syntax forms (`s.trim()`, `s.indexOf(..)`,
// `s.lastIndexOf(..)`, `s.startsWith(..)`, `s.toLower()`, ...) that lower to
// BCL `System.String` instance methods.  `substring`/`replace`/`length`/
// indexing landed earlier; this adds the remaining methods.
package Std.String.MethodTests

import Std.Core
import Std.String
import Std.Testing

func testTrim(): Unit {
  assertEqual("  hi  ".trim(), "hi", "trim both")
  assertEqual("hi".trim(), "hi", "trim no-op")
}

func testSearch(): Unit {
  val s = "abcabc"
  // BCL semantics: Int result, -1 when absent (distinct from the
  // free-function `indexOf` which returns Option[Int]).
  assertEqualInt(s.indexOf("bc"), 1, "indexOf first")
  assertEqualInt(s.lastIndexOf("bc"), 4, "lastIndexOf last")
  assertEqualInt(s.indexOf("zz"), -1, "indexOf absent is -1")
  assertEqualInt(s.lastIndexOf("zz"), -1, "lastIndexOf absent is -1")
  assertTrue(s.startsWith("abc"), "startsWith")
  assertTrue(not s.startsWith("zz"), "startsWith no match")
  assertTrue(s.endsWith("abc"), "endsWith")
  assertTrue(not s.endsWith("zz"), "endsWith no match")
}

func testCase(): Unit {
  assertEqual("Hello".toLower(), "hello", "toLower")
  assertEqual("Hello".toUpper(), "HELLO", "toUpper")
}

func main(): Unit {
  testTrim()
  testSearch()
  testCase()
  println("string_methods: ok")
}
