//! tests/flags_aspect_weaving_tests.l — runtime weaving tests for the
//! Flags.Aspects.FlagGated template.
//!
//! Unlike flags_tests.l (which tests the FlagStore API directly), this
//! module instantiates FlagGated against a handler and asserts the *woven*
//! handler actually gates on Flags.Registry, the process-global registry —
//! that registry used to be an `extern package` that silently never bound to
//! anything on either backend (issue #5324), so `FlagGated` always fell
//! through to `defaultOnMissing` no matter what was registered. Nobody
//! noticed because `FlagGated` was never applied anywhere in the repo. This
//! is the CI guard against that regression. Mirrors the pattern in
//! lyric-cache/tests/cache_aspect_weaving_tests.l.
@test_module
package Flags.FlagsAspectWeavingTests

import Std.Core
import Std.Testing
import Flags.Aspects
import Flags.Registry as FlagsRegistry

// Module-level state must be a `var`-field record bound via `val` (Lyric has
// no module-level `var` primitive) — mirrors Flags.Registry's own
// `val globalRegistry: FlagRegistryStore = ...` pattern.
record CallCounter {
  var count: Int
}

// ─── Disabled-by-default gating ─────────────────────────────────────────────
aspect CheckoutGate from Flags.Aspects.FlagGated {
  matches: name like "gatedHandler*"
  config {
    flagName: String = "new-checkout"
    defaultOnMissing: Bool = false
  }
}

val gatedHandlerCalls: CallCounter = CallCounter(count = 0)

pub func gatedHandler(): Result[String, String] {
  gatedHandlerCalls.count = gatedHandlerCalls.count + 1
  return Ok("ran")
}

test "FlagGated aspect: an unregistered flag with defaultOnMissing=false short-circuits and never runs the handler" {
  gatedHandlerCalls.count = 0
  match gatedHandler() {
    case Ok(_) -> assertTrue(false, "handler must not run when the flag is absent and defaultOnMissing=false")
    case Err(msg) -> assertEqual(msg, "feature disabled: new-checkout", "error message names the flag")
  }
  assertEqualInt(gatedHandlerCalls.count, 0, "the handler body never ran")
}

test "FlagGated aspect: registering the flag as true in Flags.Registry lets the handler proceed" {
  gatedHandlerCalls.count = 0
  FlagsRegistry.registerBoolFlag("new-checkout", true)
  match gatedHandler() {
    case Ok(v) -> assertEqual(v, "ran", "handler runs and returns its value")
    case Err(_) -> assertTrue(false, "handler must run once the flag is registered as enabled")
  }
  assertEqualInt(gatedHandlerCalls.count, 1, "the handler body ran exactly once")
  FlagsRegistry.registerBoolFlag("new-checkout", false)
}

test "FlagGated aspect: registering the flag as false in Flags.Registry keeps short-circuiting" {
  gatedHandlerCalls.count = 0
  FlagsRegistry.registerBoolFlag("new-checkout", false)
  match gatedHandler() {
    case Ok(_) -> assertTrue(false, "handler must not run once the flag is registered as disabled")
    case Err(msg) -> assertEqual(msg, "feature disabled: new-checkout", "error message names the flag")
  }
  assertEqualInt(gatedHandlerCalls.count, 0, "the handler body never ran")
}

// ─── defaultOnMissing=true ───────────────────────────────────────────────────
aspect DefaultOnGate from Flags.Aspects.FlagGated {
  matches: name like "defaultOnHandler*"
  config {
    flagName: String = "unregistered-flag"
    defaultOnMissing: Bool = true
  }
}

val defaultOnHandlerCalls: CallCounter = CallCounter(count = 0)

pub func defaultOnHandler(): Result[String, String] {
  defaultOnHandlerCalls.count = defaultOnHandlerCalls.count + 1
  return Ok("ran")
}

test "FlagGated aspect: defaultOnMissing=true proceeds when the flag was never registered" {
  defaultOnHandlerCalls.count = 0
  match defaultOnHandler() {
    case Ok(v) -> assertEqual(v, "ran", "handler runs when defaultOnMissing=true and the flag is absent")
    case Err(_) -> assertTrue(false, "handler must run")
  }
  assertEqualInt(defaultOnHandlerCalls.count, 1, "the handler body ran exactly once")
}

// ─── enabled=false master switch bypasses the registry entirely ────────────
aspect DisabledMasterSwitchGate from Flags.Aspects.FlagGated {
  matches: name like "masterOffHandler*"
  config {
    enabled: Bool = false
    flagName: String = "irrelevant-flag"
  }
}

val masterOffHandlerCalls: CallCounter = CallCounter(count = 0)

pub func masterOffHandler(): Result[String, String] {
  masterOffHandlerCalls.count = masterOffHandlerCalls.count + 1
  return Ok("ran")
}

test "FlagGated aspect: enabled=false on the aspect itself always proceeds, ignoring the registry" {
  masterOffHandlerCalls.count = 0
  match masterOffHandler() {
    case Ok(v) -> assertEqual(v, "ran", "handler runs when the aspect's own master switch is off")
    case Err(_) -> assertTrue(false, "handler must run")
  }
  assertEqualInt(masterOffHandlerCalls.count, 1, "the handler body ran exactly once")
}

// ─── Registry API directly ───────────────────────────────────────────────────
test "Flags.Registry: registerStringFlag/getStringFlag round-trip a String value" {
  FlagsRegistry.registerStringFlag("theme", "dark")
  assertEqual(FlagsRegistry.getStringFlag("theme", "light"), "dark", "registered String value is returned")
  assertEqual(
    FlagsRegistry.getStringFlag("never-registered", "fallback"),
    "fallback",
    "unregistered String flag falls back to default"
  )
}
