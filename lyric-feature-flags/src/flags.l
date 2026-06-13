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
/// In-process flag store backed by a `Map[String, FlagValue]`.
///
/// Values are stored as typed `FlagValue`s directly (String keys, so there is
/// no non-String Map-indexing concern), preserving full type fidelity for Bool,
/// String, Int, and Float flags.  `names` tracks insertion order so `listFlags`
/// can enumerate (the `Map` extern exposes no key iteration), and `descMap`
/// carries each flag's description for round-tripping through `listFlags`.
///
/// Not thread-safe in v1.  For concurrent access, wrap in a `protected type`
/// once the protected-type weaver ships, or use a remote-backed implementation.
@stable(since = "0.1")
pub record InProcessFlagStore {
  var valueMap: Map[String, FlagValue]
  var names: List[String]
  var descMap: Map[String, String]
}

impl FlagStore for InProcessFlagStore {
  func isEnabled(name: in String): Bool {
    match mapGet(self.valueMap, name) {
      case Some(fv) -> return getBoolVal(fv)
      case None -> return false
    }
  }

  func getValue(name: in String): Option[FlagValue] {
    return mapGet(self.valueMap, name)
  }

  func listFlags(): slice[FlagEntry] {
    var acc: List[FlagEntry] = newList()
    for n in self.names {
      match mapGet(self.valueMap, n) {
        case Some(fv) -> {
          val desc = match mapGet(self.descMap, n) { case Some(d) -> d; case None -> "" }
          acc.add(FlagEntry(name = n, value = fv, description = desc))
        }
        case None -> ()
      }
    }
    return acc.toArray()
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
  return InProcessFlagStore(valueMap = newMap(), names = newList(), descMap = newMap())
}

/// Create an in-process flag store pre-loaded with the given entries.
/// Later entries with a duplicate name overwrite earlier ones; each name is
/// listed once for `listFlags`.
@stable(since = "0.1")
pub func fromEntries(entries: in slice[FlagEntry]): InProcessFlagStore {
  var vm: Map[String, FlagValue] = newMap()
  var nm: List[String] = newList()
  var dmap: Map[String, String] = newMap()
  for fe in entries {
    if not vm.containsKey(fe.name) {
      nm.add(fe.name)
    }
    vm[fe.name] = fe.value
    dmap[fe.name] = fe.description
  }
  return InProcessFlagStore(valueMap = vm, names = nm, descMap = dmap)
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
  match store.getValue(name) {
    case None -> return def
    case Some(fv) -> match fv { case FlagBool(v) -> return v; case _ -> return def }
  }
}

/// Return the String value of the named flag, or `def` if absent or non-String.
@stable(since = "0.1")
pub func getString(store: in FlagStore, name: in String, def: in String): String
  requires: name.length > 0
{
  match store.getValue(name) {
    case None -> return def
    case Some(fv) -> match fv { case FlagString(v) -> return v; case _ -> return def }
  }
}

/// Return the Int value of the named flag, or `def` if absent or non-Int.
@stable(since = "0.1")
pub func getInt(store: in FlagStore, name: in String, def: in Int): Int
  requires: name.length > 0
{
  match store.getValue(name) {
    case None -> return def
    case Some(fv) -> match fv { case FlagInt(v) -> return v; case _ -> return def }
  }
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
// Receiving `fv` as a typed parameter lets the emitter resolve the union cases.
/// The Bool payload of a `FlagBool`, or `false` for any other variant.
func getBoolVal(fv: in FlagValue): Bool {
  match fv {
    case FlagBool(v) -> return v
    case FlagString(_) -> return false
    case FlagInt(_) -> return false
    case FlagFloat(_) -> return false
  }
}
