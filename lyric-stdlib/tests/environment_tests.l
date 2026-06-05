//! stdlib/tests/environment_tests.l — Tests for Std.Environment.
//!
//! Covers: getVar for an unknown variable, getVar for an empty key,
//! getVarOrDefault, args (returns a slice without panicking), and
//! runtimeDirectory (links on every target).
package Std.Environment.Tests

import Std.Core
import Std.Environment
import Std.Testing

func testGetVarMissing(): Unit {
  match getVar("LYRIC_TEST_DEFINITELY_NONEXISTENT_XYZ123") {
    case Ok(_) -> assertTrue(false, "nonexistent var should not be Ok")
    case Err(e) -> assertTrue(true, "nonexistent var returns Err")
  }
}

func testGetVarEmptyKey(): Unit {
  match getVar("") {
    case Ok(_) -> assertTrue(false, "empty key should not be Ok")
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

func testRuntimeDirectoryLinks(): Unit {
  val dir = runtimeDirectory()
  assertTrue(dir.length >= 0, "runtimeDirectory returns a valid string")
}

func main(): Unit {
  testGetVarMissing()
  testGetVarEmptyKey()
  testGetVarOrDefaultFallback()
  testGetVarOrDefaultEmpty()
  testArgsReturnsSlice()
  testRuntimeDirectoryLinks()
  println("environment_tests: ok")
}
