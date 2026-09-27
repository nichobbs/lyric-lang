//! stdlib/tests/environment_tests.l — Tests for Std.Environment.
//!
//! Covers: a setVar/getVar round-trip for a PRESENT variable (the
//! guard against the `case null` catch-all miscompile that made every
//! lookup report absent), getVar for an unknown variable, getVar for
//! an empty key, getVarOrDefault, args (returns a slice without
//! panicking), overwriting a set variable, setting an empty value
//! (verified, #7546: this does NOT unset — `getVar` still reports
//! `Ok("")`, matching the real `System.Environment
//! .SetEnvironmentVariable(key, "")` behaviour), and a spawned child
//! process inheriting `setVar` overrides (on JVM this exercises the
//! `Std.EnvironmentHost` overlay and its copy onto `ProcessBuilder
//! .environment()`; on dotnet and native it exercises the real process
//! environment block a child already inherits).
package Std.Environment.Tests

import Std.Core
import Std.Collections
import Std.Environment
import Std.Process
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

// #7546: a second setVar for the same key replaces the first, on every
// target (the JVM overlay's `envOverlay.put` replaces rather than merges).
func testSetVarOverwrite(): Unit {
  setVar("LYRIC_TEST_ENV_OVERWRITE", "first")
  assertTrue(getVarOrDefault("LYRIC_TEST_ENV_OVERWRITE", "<missing>") == "first", "first value observed")
  setVar("LYRIC_TEST_ENV_OVERWRITE", "second")
  assertTrue(getVarOrDefault("LYRIC_TEST_ENV_OVERWRITE", "<missing>") == "second", "second setVar replaces the first")
  setVar("LYRIC_TEST_ENV_OVERWRITE", "")
}

// #7546: setVar(key, "") sets the variable to an EMPTY STRING, not unset —
// verified against the real BCL: `System.Environment
// .SetEnvironmentVariable(key, "")` has no way to remove a variable from a
// non-nullable `String` value, so `getVar` afterwards still reports
// `Ok("")`, never `Err(KeyNotFound)`.  Every kernel twin matches this
// exactly (dotnet delegates to the BCL directly; the JVM overlay and
// native's `setenv(3)` both record the empty value as present).
func testSetVarEmptyValue(): Unit {
  setVar("LYRIC_TEST_ENV_EMPTY", "present")
  assertTrue(getVarOrDefault("LYRIC_TEST_ENV_EMPTY", "<missing>") == "present", "set before overwrite")
  setVar("LYRIC_TEST_ENV_EMPTY", "")
  match getVar("LYRIC_TEST_ENV_EMPTY") {
    case Ok(v) -> assertEqual(v, "", "an empty setVar sets the value to \"\", it does not unset")
    case Err(_) -> assertTrue(false, "a setVar-set variable, even with an empty value, is still present")
  }
  assertTrue(getVarOrDefault("LYRIC_TEST_ENV_EMPTY", "<default>") == "", "getVarOrDefault sees the empty value too")
}

// #7546: a value set via setVar is visible to a spawned child process — on
// dotnet/native because setVar mutates the real process environment block a
// child already inherits, and on JVM because `Std.ProcessCaptureHost` copies
// the `Std.EnvironmentHost` overlay onto the child's `ProcessBuilder
// .environment()` before `start()`.  Uses `Std.Process.runCapture` (not
// `Std.ProcessCapture`) because it is the one capture API all three kernel
// twins implement, including `--target native`.
func testSetVarChildProcessInheritance(): Unit {
  setVar("LYRIC_TEST_ENV_CHILD", "seen-by-child")
  val args: List[String] = newList()
  args.add("-c")
  args.add("printf '%s' \"$LYRIC_TEST_ENV_CHILD\"")
  match runCapture("sh", args, 10000) {
    case Ok(r) -> assertEqual(r.stdout, "seen-by-child", "child process observes a setVar override")
    case Err(e) -> assertTrue(false, "sh spawn failed: " + e)
  }
  setVar("LYRIC_TEST_ENV_CHILD", "")
}

// #7546: a spawned child sees the LATEST setVar value for a key, not a
// stale first value — including when the latest value is empty (setVar
// never unsets; see testSetVarEmptyValue).  Covers the overlay-overwrite
// path (`envOverlay.put` on JVM) reaching the child the same way a second
// real `setenv(3)` call does on dotnet/native.
func testSetVarChildProcessSeesLatestValue(): Unit {
  setVar("LYRIC_TEST_ENV_CHILD_LATEST", "should-not-be-seen")
  setVar("LYRIC_TEST_ENV_CHILD_LATEST", "")
  val args: List[String] = newList()
  args.add("-c")
  args.add("printf '[%s]' \"$LYRIC_TEST_ENV_CHILD_LATEST\"")
  match runCapture("sh", args, 10000) {
    case Ok(r) -> assertEqual(r.stdout, "[]", "child sees the overwritten (empty) value, not the first one")
    case Err(e) -> assertTrue(false, "sh spawn failed: " + e)
  }
}

func main(): Unit {
  testGetVarPresentRoundTrip()
  testGetVarMissing()
  testGetVarEmptyKey()
  testGetVarOrDefaultFallback()
  testGetVarOrDefaultEmpty()
  testArgsReturnsSlice()
  testSetVarOverwrite()
  testSetVarEmptyValue()
  testSetVarChildProcessInheritance()
  testSetVarChildProcessSeesLatestValue()
  println("environment_tests: ok")
}
