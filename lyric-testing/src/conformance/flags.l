//! Testing.Conformance.Flags — conformance suite for `Flags.FlagStore`.
//!
//! `run(factory)`: `factory(entries)` returns a store already holding
//! `entries`.  The interface has no mutating operation (a store is
//! populated when it is built, or by its backend), so every case seeds its
//! store through the factory.  A remote-backed store seeds a fixture
//! endpoint and returns a client of it.
@runtime_checked
@io
package Testing.Conformance.Flags

import Std.Core
import Std.Collections
import Testing.Conformance
import Flags as FlagsLib

/// Run the `FlagStore` contract against stores from `factory`.
@stable(since = "0.1")
pub func run(factory: (slice[FlagsLib.FlagEntry]) -> FlagsLib.FlagStore): Checks {
  val c = newChecks("FlagStore")
  runCase(c, "an empty store has no flags", { -> emptyStore(c, factory([])) })
  runCase(c, "a Bool flag reports its value through isEnabled", { -> boolFlags(c, factory(boolEntries())) })
  runCase(c, "a missing flag is disabled and has no value", { -> missingFlag(c, factory(boolEntries())) })
  runCase(c, "only a true Bool flag is enabled", { -> nonBoolNotEnabled(c, factory(typedEntries())) })
  runCase(c, "typed values round-trip through getValue", { -> typedValues(c, factory(typedEntries())) })
  runCase(c, "listFlags returns every flag with its value and description", { -> listing(c, factory(typedEntries())) })
  runCase(c, "refresh succeeds and leaves the flags readable", { -> refreshKeepsFlags(c, factory(typedEntries())) })
  runCase(c, "the typed accessors fall back to their default", { -> accessors(c, factory(typedEntries())) })
  return c
}

func boolEntries(): slice[FlagsLib.FlagEntry] {
  return [FlagsLib.makeFlag("on", true), FlagsLib.makeFlag("off", false)]
}

func typedEntries(): slice[FlagsLib.FlagEntry] {
  return [
    FlagsLib.makeFlagWithDesc("checkout", true, "new checkout flow"),
    FlagsLib.makeFlag("legacy", false),
    FlagsLib.makeStringFlag("banner", "spring"),
    FlagsLib.makeIntFlag("limit", 25),
    FlagsLib.makeFloatFlag("ratio", 0.5)
  ]
}

func emptyStore(c: in Checks, store: in FlagsLib.FlagStore): Unit {
  expectEqualInt(c, store.listFlags().length, 0, "an empty store lists nothing")
  expectTrue(c, not store.isEnabled("anything"), "no flag is enabled in an empty store")
}

func boolFlags(c: in Checks, store: in FlagsLib.FlagStore): Unit {
  expectTrue(c, store.isEnabled("on"), "a true flag is enabled")
  expectTrue(c, not store.isEnabled("off"), "a false flag is not enabled")
}

func missingFlag(c: in Checks, store: in FlagsLib.FlagStore): Unit {
  expectTrue(c, not store.isEnabled("nope"), "a missing flag is not enabled")
  expectTrue(c, not isSome(store.getValue("nope")), "a missing flag has no value")
}

func nonBoolNotEnabled(c: in Checks, store: in FlagsLib.FlagStore): Unit {
  expectTrue(c, not store.isEnabled("banner"), "a String flag is not enabled")
  expectTrue(c, not store.isEnabled("limit"), "an Int flag is not enabled")
  expectTrue(c, not store.isEnabled("ratio"), "a Float flag is not enabled")
  expectTrue(c, store.isEnabled("checkout"), "a true Bool flag among typed ones is enabled")
}

func typedValues(c: in Checks, store: in FlagsLib.FlagStore): Unit {
  match store.getValue("checkout") {
    case Some(FlagsLib.FlagBool(v)) -> expectTrue(c, v, "checkout is Bool true")
    case _ -> failCase(c, "checkout should be a FlagBool")
  }
  match store.getValue("banner") {
    case Some(FlagsLib.FlagString(v)) -> expectEqual(c, v, "spring", "banner is String \"spring\"")
    case _ -> failCase(c, "banner should be a FlagString")
  }
  match store.getValue("limit") {
    case Some(FlagsLib.FlagInt(v)) -> expectEqualInt(c, v, 25, "limit is Int 25")
    case _ -> failCase(c, "limit should be a FlagInt")
  }
  match store.getValue("ratio") {
    case Some(FlagsLib.FlagFloat(v)) -> expectTrue(c, v == 0.5, "ratio is Float 0.5")
    case _ -> failCase(c, "ratio should be a FlagFloat")
  }
}

func listing(c: in Checks, store: in FlagsLib.FlagStore): Unit {
  val all = store.listFlags()
  expectEqualInt(c, all.length, 5, "every flag is listed once")
  var sawCheckout = false
  var sawBanner = false
  for f in all {
    if f.name == "checkout" {
      sawCheckout = true
      expectEqual(c, f.description, "new checkout flow", "the description is carried")
    }
    if f.name == "banner" {
      sawBanner = true
    }
  }
  expectTrue(c, sawCheckout, "checkout is listed")
  expectTrue(c, sawBanner, "banner is listed")
}

func refreshKeepsFlags(c: in Checks, store: in FlagsLib.FlagStore): Unit {
  match store.refresh() {
    case Ok(_) -> expectTrue(c, store.isEnabled("checkout"), "flags survive a refresh")
    case Err(e) -> failCase(c, "refresh failed: " + e.message)
  }
}

func accessors(c: in Checks, store: in FlagsLib.FlagStore): Unit {
  expectTrue(c, FlagsLib.getBool(store, "checkout", false), "getBool of a set flag")
  expectTrue(c, FlagsLib.getBool(store, "absent", true), "getBool falls back to the default")
  expectEqual(c, FlagsLib.getString(store, "banner", "x"), "spring", "getString of a set flag")
  expectEqual(c, FlagsLib.getString(store, "absent", "fallback"), "fallback", "getString falls back")
  expectEqualInt(c, FlagsLib.getInt(store, "limit", 0), 25, "getInt of a set flag")
  expectEqualInt(c, FlagsLib.getInt(store, "absent", 7), 7, "getInt falls back")
  expectTrue(c, FlagsLib.getFloat(store, "ratio", 0.0) == 0.5, "getFloat of a set flag")
  expectTrue(c, FlagsLib.getFloat(store, "absent", 1.5) == 1.5, "getFloat falls back")
}
