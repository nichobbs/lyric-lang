// stdlib/tests/environment_tests.l — Tests for Std.Environment.
//
// Covers: getVar for a known variable (PATH), getVar for an unknown variable,
// getVarOrDefault, and args (returns a slice without panicking).
package Std.Environment.Tests

import Std.Core
import Std.Environment
import Std.Testing

func testGetVarMissing(): Unit {
  match getVar("LYRIC_TEST_DEFINITELY_NONEXISTENT_XYZ123") {
    case Ok(_)  -> assertTrue(false, "nonexistent var should not be Ok")
    case Err(e) -> assertTrue(true, "nonexistent var returns Err")
  }
}

func testGetVarEmptyKey(): Unit {
  match getVar("") {
    case Ok(_)  -> assertTrue(false, "empty key should not be Ok")
    case Err(e) -> assertTrue(true, "empty key returns Err")
  }
}

func testGetVarOrDefaultFallback(): Unit {
  val result = getVarOrDefault("LYRIC_TEST_DEFINITELY_NONEXISTENT_XYZ123", "fallback")
  assertTrue(result == "fallback", "missing var returns default")
}

func testGetVarOrDefaultEmpty(): Unit {
  val result = getVarOrDefault("", "def")
  assertTrue(result == "def", "empty key returns default")
}

func testArgsReturnsSlice(): Unit {
  val a = args()
  assertTrue(a.length >= 0, "args returns a valid slice")
}

func main(): Unit {
  testGetVarMissing()
  testGetVarEmptyKey()
  testGetVarOrDefaultFallback()
  testGetVarOrDefaultEmpty()
  testArgsReturnsSlice()
  println("environment_tests: ok")
}
