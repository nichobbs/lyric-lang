//! tests/flags_tests.l — test suite for the Flags package.
//! Covers the in-process store: factory functions, isEnabled, getValue,
//! getBool, getString, getInt, refresh, and flag construction helpers.
@test_module
package Flags.FlagsTests

import Std.Core
import Std.Testing
import Flags

// ─── inProcess factory ────────────────────────────────────────────────────────
test "inProcess: creates an empty store where every flag is absent" {
  val store = Flags.inProcess()
  match Flags.getValue(store, "any-flag") {
    case None -> ()
    case Some(_) -> assertTrue(false, "empty store must return None for any flag")
  }
}

test "inProcess: isEnabled returns false for a flag that was never registered" {
  val store = Flags.inProcess()
  assertTrue(not Flags.isEnabled(store, "unknown"), "absent flag must not be enabled")
}

// ─── fromEntries factory ──────────────────────────────────────────────────────
test "fromEntries: enabled Bool flag is reported as enabled" {
  val store = Flags.fromEntries([Flags.makeFlag("feature-a", true)])
  assertTrue(Flags.isEnabled(store, "feature-a"), "enabled Bool flag must be enabled")
}

test "fromEntries: disabled Bool flag is not reported as enabled" {
  val store = Flags.fromEntries([Flags.makeFlag("feature-b", false)])
  assertTrue(not Flags.isEnabled(store, "feature-b"), "disabled Bool flag must not be enabled")
}

test "fromEntries: multiple flags coexist correctly" {
  val store = Flags.fromEntries([Flags.makeFlag("on", true), Flags.makeFlag("off", false)])
  assertTrue(Flags.isEnabled(store, "on"), "flag 'on' must be enabled")
  assertTrue(not Flags.isEnabled(store, "off"), "flag 'off' must not be enabled")
}

test "fromEntries: flag not in the list is absent" {
  val store = Flags.fromEntries([Flags.makeFlag("known", true)])
  assertTrue(not Flags.isEnabled(store, "unknown"), "flag not registered must not be enabled")
}

// ─── makeFlag ─────────────────────────────────────────────────────────────────
test "makeFlag: creates a Bool FlagEntry with the given name and enabled state" {
  val entry = Flags.makeFlag("new-ui", true)
  assertEqual(entry.name, "new-ui", "entry name")
  match entry.value {
    case FlagValue.FlagBool(v) -> assertTrue(v, "FlagBool value must be true")
    case FlagValue.FlagString(_) -> assertTrue(false, "expected FlagBool, got FlagString")
    case FlagValue.FlagInt(_) -> assertTrue(false, "expected FlagBool, got FlagInt")
    case FlagValue.FlagFloat(_) -> assertTrue(false, "expected FlagBool, got FlagFloat")
  }
}

test "makeFlag: disabled flag has FlagBool(false)" {
  val entry = Flags.makeFlag("kill-switch", false)
  match entry.value {
    case FlagValue.FlagBool(v) -> assertTrue(not v, "FlagBool value must be false")
    case _ -> assertTrue(false, "expected FlagBool variant")
  }
}

test "makeFlag: description field is empty" {
  val entry = Flags.makeFlag("simple", true)
  assertEqual(entry.description, "", "description must be empty for makeFlag")
}

// ─── makeFlagWithDesc ─────────────────────────────────────────────────────────
test "makeFlagWithDesc: creates a Bool FlagEntry with the given description" {
  val entry = Flags.makeFlagWithDesc("dark-mode", true, "Enable dark mode UI")
  assertEqual(entry.name, "dark-mode", "entry name")
  assertEqual(entry.description, "Enable dark mode UI", "description")
  match entry.value {
    case FlagValue.FlagBool(v) -> assertTrue(v, "must be enabled")
    case _ -> assertTrue(false, "expected FlagBool variant")
  }
}

test "makeFlagWithDesc: empty description is accepted" {
  val entry = Flags.makeFlagWithDesc("flag", false, "")
  assertEqual(entry.description, "", "empty description round-trips")
}

// ─── isEnabled ────────────────────────────────────────────────────────────────
test "isEnabled: returns false for absent flag" {
  val store = Flags.inProcess()
  assertTrue(not Flags.isEnabled(store, "not-here"), "absent flag must not be enabled")
}

test "isEnabled: returns true for enabled Bool flag" {
  val store = Flags.fromEntries([Flags.makeFlag("go", true)])
  assertTrue(Flags.isEnabled(store, "go"), "enabled flag must return true")
}

test "isEnabled: returns false for disabled Bool flag" {
  val store = Flags.fromEntries([Flags.makeFlag("stop", false)])
  assertTrue(not Flags.isEnabled(store, "stop"), "disabled flag must return false")
}

// ─── getValue ─────────────────────────────────────────────────────────────────
test "getValue: returns None for absent flag" {
  val store = Flags.inProcess()
  match Flags.getValue(store, "missing") {
    case None -> ()
    case Some(_) -> assertTrue(false, "absent flag must return None")
  }
}

test "getValue: returns Some(FlagBool) for a Bool flag" {
  val store = Flags.fromEntries([Flags.makeFlag("beta", true)])
  match Flags.getValue(store, "beta") {
    case None -> assertTrue(false, "expected Some for registered flag")
    case Some(v) -> match v { case FlagValue.FlagBool(b) -> assertTrue(b, "must be true"); case _ -> assertTrue(false, "expected FlagBool") }
  }
}

test "getValue: returns Some for a disabled Bool flag" {
  val store = Flags.fromEntries([Flags.makeFlag("off-flag", false)])
  match Flags.getValue(store, "off-flag") {
    case None -> assertTrue(false, "expected Some even for disabled flag")
    case Some(v) -> match v { case FlagValue.FlagBool(b) -> assertTrue(not b, "must be false"); case _ -> assertTrue(false, "expected FlagBool") }
  }
}

// ─── getBool ──────────────────────────────────────────────────────────────────
test "getBool: returns flag value when flag is present and enabled" {
  val store = Flags.fromEntries([Flags.makeFlag("my-flag", true)])
  assertTrue(Flags.getBool(store, "my-flag", false), "enabled flag must return true")
}

test "getBool: returns flag value when flag is disabled" {
  val store = Flags.fromEntries([Flags.makeFlag("my-flag", false)])
  assertTrue(not Flags.getBool(store, "my-flag", true), "disabled flag must return false, not the default")
}

test "getBool: returns defaultValue when flag is absent" {
  val store = Flags.inProcess()
  assertTrue(Flags.getBool(store, "absent", true), "default=true returned when absent")
  assertTrue(not Flags.getBool(store, "absent", false), "default=false returned when absent")
}

// ─── getString ────────────────────────────────────────────────────────────────
test "getString: returns defaultValue when flag is absent" {
  val store = Flags.inProcess()
  assertEqual(Flags.getString(store, "theme", "blue"), "blue", "default value returned when flag absent")
}

test "getString: returns defaultValue when flag is a Bool (non-String type)" {
  val store = Flags.fromEntries([Flags.makeFlag("bool-flag", true)])
  assertEqual(Flags.getString(store, "bool-flag", "default"), "default", "non-String flag must fall back to default")
}

// ─── getInt ───────────────────────────────────────────────────────────────────
test "getInt: returns defaultValue when flag is absent" {
  val store = Flags.inProcess()
  assertEqualInt(Flags.getInt(store, "max-retries", 3), 3, "default value returned when flag absent")
}

test "getInt: returns defaultValue when flag is a Bool (non-Int type)" {
  val store = Flags.fromEntries([Flags.makeFlag("bool-flag", false)])
  assertEqualInt(Flags.getInt(store, "bool-flag", 99), 99, "non-Int flag must fall back to default")
}

// ─── refresh ──────────────────────────────────────────────────────────────────
test "refresh: in-process store returns Ok(())" {
  val store = Flags.inProcess()
  match Flags.refresh(store) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "refresh on in-process store must return Ok: " + e.message)
  }
}

test "refresh: fromEntries store returns Ok(())" {
  val store = Flags.fromEntries([Flags.makeFlag("f", true)])
  match Flags.refresh(store) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "refresh on fromEntries store must return Ok: " + e.message)
  }
}
