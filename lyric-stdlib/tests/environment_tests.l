//! stdlib/tests/environment_tests.l — Tests for Std.Environment.
//!
//! Covers: a setVar/getVar round-trip for a PRESENT variable (the
//! guard against the `case null` catch-all miscompile that made every
//! lookup report absent), getVar for an unknown variable, getVar for
//! an empty key, getVarOrDefault, and args (returns a slice without
//! panicking).
package Std.Environment.Tests

import Std.Core
import Std.Environment
import Std.Testing

func testGetVarPresentRoundTrip(): Unit {
  setVar("LYRIC_TEST_ENV_ROUNDTRIP", "round-trip-value")
  var got = ""
  match getVar("LYRIC_TEST_ENV_ROUNDTRIP") {
    case Ok(v) -> {
      got = v
    }
    case Err(_) -> {
      got = "<KeyNotFound>"
    }
  }
  assertTrue(got == "round-trip-value", "present var returns its value, got: " + got)
  val viaDefault = getVarOrDefault("LYRIC_TEST_ENV_ROUNDTRIP", "WRONG")
  assertTrue(viaDefault == "round-trip-value", "present var ignores the default")
}

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
  val fetched = getVarOrDefault("LYRIC_TEST_DEFINITELY_NONEXISTENT_XYZ123", "fallback")
  assertTrue(fetched == "fallback", "missing var returns default")
}

func testGetVarOrDefaultEmpty(): Unit {
  val fetched = getVarOrDefault("", "def")
  assertTrue(fetched == "def", "empty key returns default")
}

func testArgsReturnsSlice(): Unit {
  val a = args()
  assertTrue(a.length >= 0, "args returns a valid slice")
}

func main(): Unit {
  testGetVarPresentRoundTrip()
  testGetVarMissing()
  testGetVarEmptyKey()
  testGetVarOrDefaultFallback()
  testGetVarOrDefaultEmpty()
  testArgsReturnsSlice()
  println("environment_tests: ok")
}
