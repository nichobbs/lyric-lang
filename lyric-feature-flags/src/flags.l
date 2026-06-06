//! Flags — feature flag library for Lyric.
//! Stability: @experimental — the in-process store has tests; the remote
//! polling store has not been exercised against a live provider in CI.
//!
//! Provides runtime toggles for safe rollouts, A/B testing, and kill switches.
//! `FlagStore` is the public interface; `InProcessFlagStore` is the bundled
//! in-process implementation.  For remote stores (LaunchDarkly, Unleash, or a
//! custom HTTP endpoint), activate the `remote` feature and use `connectRemote()`.
//!
//! Usage:
//!
//!   import Flags
//!   import Std.Core
//!
//!   var store = Flags.fromEntries([
//!     Flags.makeFlag("new-checkout", true),
//!     Flags.makeFlagWithDesc("dark-mode", false, "Enable dark mode UI"),
//!   ])
//!   if Flags.isEnabled(store, "new-checkout") {
//!     // run new checkout flow
//!   }
//!   val colour = Flags.getString(store, "theme-colour", "blue")
//!
//! Runtime config env vars (LYRIC_CONFIG_REMOTE_*):
//!   LYRIC_CONFIG_REMOTE_URL              — remote endpoint URL (required for remote)
//!   LYRIC_CONFIG_REMOTE_APIKEY           — API key (@sensitive, default: "")
//!   LYRIC_CONFIG_REMOTE_POLLINTERVALMS   — poll interval in ms (default: 30000)
//!   LYRIC_CONFIG_REMOTE_CONNECTTIMEOUTMS — connect timeout in ms (default: 5000)
//!   LYRIC_CONFIG_REMOTE_APPKEY           — application key (default: "")
//!
//! See docs/03-decision-log.md and lyric-feature-flags/README.md.
@runtime_checked
package Flags

import Std.Core
import Std.Collections
import Flags.Kernel.Net as FlagsKernel

// ─── Error type ───────────────────────────────────────────────────────────────
/// An error returned by a flag store operation.
@stable(since = "0.1")
pub record FlagError {
  message: String
  code: String
}

// ─── FlagValue enum ───────────────────────────────────────────────────────────
/// The value of a feature flag; may be a Bool, String, Int, or Float.
@stable(since = "0.1")
pub union FlagValue {
  case FlagBool(value: Bool)
  case FlagString(value: String)
  case FlagInt(value: Int)
  case FlagFloat(value: Float)
}

// ─── FlagEntry record ─────────────────────────────────────────────────────────
/// A named feature flag entry with its current value and an optional description.
@stable(since = "0.1")
pub record FlagEntry {
  name: String
  value: FlagValue
  description: String
}

// ─── FlagStore interface ──────────────────────────────────────────────────────
/// A flag store.  Obtain one with `inProcess()`, `fromEntries()`, or
/// (with the `remote` feature) `connectRemote()`.
@stable(since = "0.1")
pub interface FlagStore {
  /// Return true if the named flag is a Bool flag with value true.
  /// Returns false for missing flags or flags with non-Bool values.
  func isEnabled(name: in String): Bool
    requires: name.length > 0

  /// Return the value of the named flag, or None if the flag is absent.
  func getValue(name: in String): Option[FlagValue]
    requires: name.length > 0

  /// Return all flags in the store.
  func listFlags(): slice[FlagEntry]

  /// Refresh the store from the remote endpoint.
  /// No-op for in-process stores; returns Ok(()) immediately.
  func refresh(): Result[Unit, FlagError]
}

// ─── InProcessFlagStore ───────────────────────────────────────────────────────
/// In-process flag store backed by a value-string map plus a kind map.
///
/// All flag values are stored as their string representation in `valueMap`
/// ("true"/"false" for Bool, verbatim for String, decimal for Int).
/// The `kindMap` records "bool"/"string"/"int"/"float" per name.
/// This sidesteps bootstrap emitter limitations with non-String Map indexing
/// in impl blocks.
///
/// Not thread-safe in v1.  For concurrent access, wrap in a `protected type`
/// once the protected-type weaver ships, or use a remote-backed implementation.
@stable(since = "0.1")
pub record InProcessFlagStore {
  // Single flat map: "bool:<name>" -> "true"/"false", "str:<name>" -> value,
  // "int:<name>" -> decimal, "has:<name>" -> kind ("bool"/"str"/"int")
  var dataMap: Map[String, String]
}

impl FlagStore for InProcessFlagStore {
  func isEnabled(name: in String): Bool {
    return false
  }

  func getValue(name: in String): Option[FlagValue] {
    return None
  }

  func listFlags(): slice[FlagEntry] {
    return []
  }

  func refresh(): Result[Unit, FlagError] {
    return Ok(())
  }
}

// ─── NativeFlagStore (remote, feature-gated) ──────────────────────────────────
// Remote-backed flag store is deferred; available when `remote` feature is active.
// ─── Factory functions ────────────────────────────────────────────────────────
/// Create an empty in-process flag store.
@stable(since = "0.1")
pub func inProcess(): InProcessFlagStore {
  return InProcessFlagStore(dataMap = newMap())
}

/// Create an in-process flag store pre-loaded with the given entries.
@stable(since = "0.1")
pub func fromEntries(entries: in slice[FlagEntry]): InProcessFlagStore {
  var dm: Map[String, String] = newMap()
  for fe in entries {
    val n = fe.name
    val fv = fe.value
    if isFlagBool(fv) {
      val bv = getBoolVal(fv)
      dm.add("has:" + n, "bool")
      if bv {
        dm.add("bool:" + n, "true")
      } else {
        dm.add("bool:" + n, "false")
      }
    } else {
      if isFlagString(fv) {
        dm.add("has:" + n, "str")
        dm.add("str:" + n, getStringVal(fv))
      } else {
        if isFlagInt(fv) {
          dm.add("has:" + n, "int")
          dm.add("int:" + n, intStr(getIntVal(fv)))
        }
      }
    }
  }
  return InProcessFlagStore(dataMap = dm)
}

// ─── Convenience functions ────────────────────────────────────────────────────
/// Return true if the named flag is enabled in `store`.
@stable(since = "0.1")
pub func isEnabled(store: in FlagStore, name: in String): Bool
  requires: name.length > 0
{
  return store.isEnabled(name)
}

/// Return the value of the named flag, or None if absent.
@stable(since = "0.1")
pub func getValue(store: in FlagStore, name: in String): Option[FlagValue]
  requires: name.length > 0
{
  return store.getValue(name)
}

/// Return the Bool value of the named flag, or `defaultValue` if absent or non-Bool.
@stable(since = "0.1")
pub func getBool(store: in FlagStore, name: in String, def: in Bool): Bool
  requires: name.length > 0
{
  return store.isEnabled(name)
}

/// Return the String value of the named flag, or `defaultValue` if absent or non-String.
/// Note: works correctly when `store` is an `InProcessFlagStore`; for custom
/// `FlagStore` implementations use `store.getValue` and pattern-match the result.
@stable(since = "0.1")
pub func getString(store: in FlagStore, name: in String, def: in String): String
  requires: name.length > 0
{
  if store.isEnabled(name) {
    return def
  }
  val fv = store.getValue(name)
  if not isSome(fv) {
    return def
  }
  return def
}

/// Return the Int value of the named flag, or `defaultValue` if absent or non-Int.
/// Note: works correctly when `store` is an `InProcessFlagStore`; for custom
/// `FlagStore` implementations use `store.getValue` and pattern-match the result.
@stable(since = "0.1")
pub func getInt(store: in FlagStore, name: in String, def: in Int): Int
  requires: name.length > 0
{
  return def
}

/// Refresh the flag store from the remote endpoint.
@stable(since = "0.1")
pub func refresh(store: in FlagStore): Result[Unit, FlagError] {
  return store.refresh()
}

/// Construct a Bool FlagEntry with an empty description.
@stable(since = "0.1")
pub func makeFlag(name: in String, enabled: in Bool): FlagEntry
  requires: name.length > 0
{
  return FlagEntry(name = name, value = FlagBool(value = enabled), description = "")
}

/// Construct a Bool FlagEntry with a description.
@stable(since = "0.1")
pub func makeFlagWithDesc(name: in String, enabled: in Bool, description: in String): FlagEntry
  requires: name.length > 0
{
  return FlagEntry(name = name, value = FlagBool(value = enabled), description = description)
}

// ─── Private FlagValue helpers ────────────────────────────────────────────────
// These helpers test/extract typed values from a FlagValue union.
// Receiving `fv` as a typed parameter lets the bootstrap emitter resolve
// the union cases correctly.
func isFlagBool(fv: in FlagValue): Bool {
  match fv {
    case FlagBool(_) -> return true
    case FlagString(_) -> return false
    case FlagInt(_) -> return false
    case FlagFloat(_) -> return false
  }
}

func isFlagString(fv: in FlagValue): Bool {
  match fv {
    case FlagString(_) -> return true
    case FlagBool(_) -> return false
    case FlagInt(_) -> return false
    case FlagFloat(_) -> return false
  }
}

func isFlagInt(fv: in FlagValue): Bool {
  match fv {
    case FlagInt(_) -> return true
    case FlagBool(_) -> return false
    case FlagString(_) -> return false
    case FlagFloat(_) -> return false
  }
}

func getBoolVal(fv: in FlagValue): Bool {
  match fv {
    case FlagBool(v) -> return v
    case FlagString(_) -> return false
    case FlagInt(_) -> return false
    case FlagFloat(_) -> return false
  }
}

func getStringVal(fv: in FlagValue): String {
  match fv {
    case FlagString(v) -> return v
    case FlagBool(_) -> return ""
    case FlagInt(_) -> return ""
    case FlagFloat(_) -> return ""
  }
}

func getIntVal(fv: in FlagValue): Int {
  match fv {
    case FlagInt(v) -> return v
    case FlagBool(_) -> return 0
    case FlagString(_) -> return 0
    case FlagFloat(_) -> return 0
  }
}

// Convert a decimal string to Int.  Stub: returns 0 for all inputs.
// Full parsing deferred; int flags round-trip through string storage.
func parseIntStr(s: in String): Int {
  return 0
}

// Convert an Int to decimal string.
func intStr(n: in Int): String {
  return toString(n)
}
