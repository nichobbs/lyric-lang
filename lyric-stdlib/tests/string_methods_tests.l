//! stdlib/tests/string_methods_tests.l — Tests for method-syntax string ops.
//!
//! `string_tests.l` covers the free-function forms (`substring(s, ..)`);
//! this file covers the UFCS/method-syntax forms (`s.trim()`, `s.indexOf(..)`,
//! `s.lastIndexOf(..)`, `s.startsWith(..)`, `s.toLower()`, ...) that lower to
//! BCL `System.String` instance methods.  `substring`/`replace`/`length`/
//! indexing landed earlier; this adds the remaining methods.
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
  // With `import Std.String` in scope the method spelling routes to the
  // Option-returning free functions on BOTH backends (#6124/#6348) — the
  // raw-int BCL semantics this file previously asserted rode the #5625
  // MSIL mis-binding.
  match s.indexOf("bc") {
    case Some(i) -> assertEqualInt(i, 1, "indexOf first")
    case None -> assertTrue(false, "indexOf: expected Some(1)")
  }
  match s.lastIndexOf("bc") {
    case Some(i) -> assertEqualInt(i, 4, "lastIndexOf last")
    case None -> assertTrue(false, "lastIndexOf: expected Some(4)")
  }
  match s.indexOf("zz") {
    case Some(_) -> assertTrue(false, "indexOf absent must be None")
    case None -> ()
  }
  match s.lastIndexOf("zz") {
    case Some(_) -> assertTrue(false, "lastIndexOf absent must be None")
    case None -> ()
  }
  assertTrue(s.contains("cab"), "contains present")
  assertTrue(not s.contains("zzz"), "contains absent")
  assertTrue(s.startsWith("abc"), "startsWith")
  assertTrue(not s.startsWith("zz"), "startsWith no match")
  assertTrue(s.endsWith("abc"), "endsWith")
  assertTrue(not s.endsWith("zz"), "endsWith no match")
}

func testCase(): Unit {
  assertEqual("Hello".toLower(), "hello", "toLower")
  assertEqual("Hello".toUpper(), "HELLO", "toUpper")
  // ToLowerInvariant / ToUpperInvariant are used deliberately so protocol
  // strings fold consistently regardless of thread culture.  The canonical
  // case is the Turkish-I problem: under tr-TR culture "I".ToLower() yields
  // "ı" (dotless i), but "I".ToLowerInvariant() always yields "i".
  assertEqual("I".toLower(), "i", "toLower invariant (not Turkish dotless-i)")
  assertEqual("HS256".toLower(), "hs256", "toLower invariant — JWT algorithm name canonical case")
  assertEqual("hs256".toUpper(), "HS256", "toUpper invariant")
}

func main(): Unit {
  testTrim()
  testSearch()
  testCase()
  println("string_methods: ok")
}
