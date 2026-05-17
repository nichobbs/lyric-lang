/// Flags — feature flag library for Lyric.
///
/// Provides runtime toggles for safe rollouts, A/B testing, and kill switches.
/// `FlagStore` is the public interface; `InProcessFlagStore` is the bundled
/// in-process implementation.  For remote stores (LaunchDarkly, Unleash, or a
/// custom HTTP endpoint), activate the `remote` feature and use `connectRemote()`.
///
/// Usage:
///
///   import Flags
///   import Std.Core
///
///   var store = Flags.fromEntries([
///     Flags.makeFlag("new-checkout", true),
///     Flags.makeFlagWithDesc("dark-mode", false, "Enable dark mode UI"),
///   ])
///   if Flags.isEnabled(store, "new-checkout") {
///     // run new checkout flow
///   }
///   val colour = Flags.getString(store, "theme-colour", "blue")
///
/// Runtime config env vars (LYRIC_CONFIG_REMOTE_*):
///   LYRIC_CONFIG_REMOTE_URL              — remote endpoint URL (required for remote)
///   LYRIC_CONFIG_REMOTE_APIKEY           — API key (@sensitive, default: "")
///   LYRIC_CONFIG_REMOTE_POLLINTERVALMS   — poll interval in ms (default: 30000)
///   LYRIC_CONFIG_REMOTE_CONNECTTIMEOUTMS — connect timeout in ms (default: 5000)
///   LYRIC_CONFIG_REMOTE_APPKEY           — application key (default: "")
///
/// See docs/03-decision-log.md and lyric-feature-flags/README.md.

@runtime_checked
package Flags

import Std.Core
import Std.Collections
import Flags.Kernel.Net

// ─── Error type ───────────────────────────────────────────────────────────────

/// An error returned by a flag store operation.
@stable(since="0.1")
pub record FlagError {
  message: String
  code:    String
}

// ─── FlagValue enum ───────────────────────────────────────────────────────────

/// The value of a feature flag; may be a Bool, String, Int, or Float.
@stable(since="0.1")
pub enum FlagValue {
  case FlagBool(value: Bool)
  case FlagString(value: String)
  case FlagInt(value: Int)
  case FlagFloat(value: Float)
}

// ─── FlagEntry record ─────────────────────────────────────────────────────────

/// A named feature flag entry with its current value and an optional description.
@stable(since="0.1")
pub record FlagEntry {
  name:        String
  value:       FlagValue
  description: String
}

// ─── FlagStore interface ──────────────────────────────────────────────────────

/// A flag store.  Obtain one with `inProcess()`, `fromEntries()`, or
/// (with the `remote` feature) `connectRemote()`.
@stable(since="0.1")
pub interface FlagStore {
  /// Return true if the named flag is a Bool flag with value true.
  /// Returns false for missing flags or flags with non-Bool values.
  func isEnabled(name: in String): Bool
    requires: name.length > 0

  /// Return the value of the named flag, or None if the flag is absent.
  func getValue(name: in String): Option[FlagValue]
    requires: name.length > 0

  /// Return all flags in the store.
  func listFlags(): [FlagEntry]

  /// Refresh the store from the remote endpoint.
  /// No-op for in-process stores; returns Ok(()) immediately.
  func refresh(): Result[Unit, FlagError]
}

// ─── InProcessFlagStore ───────────────────────────────────────────────────────

/// In-process flag store backed by a mutable `Map`.
///
/// Not thread-safe in v1.  For concurrent access, wrap in a `protected type`
/// once the protected-type weaver ships, or use a remote-backed implementation.
@stable(since="0.1")
pub record InProcessFlagStore {
  var flags: Map[String, FlagEntry]
}

impl FlagStore for InProcessFlagStore {
  func isEnabled(name: in String): Bool {
    match flags.get(name) {
      case Some(entry) ->
        match entry.value {
          case FlagValue.FlagBool(value = v) -> v
          case FlagValue.FlagString(_)       -> false
          case FlagValue.FlagInt(_)          -> false
          case FlagValue.FlagFloat(_)        -> false
        }
      case None -> false
    }
  }

  func getValue(name: in String): Option[FlagValue] {
    match flags.get(name) {
      case Some(entry) -> Some(value = entry.value)
      case None        -> None
    }
  }

  func listFlags(): [FlagEntry] {
    var result: [FlagEntry] = []
    for (_, entry) in flags {
      result = result + [entry]
    }
    return result
  }

  func refresh(): Result[Unit, FlagError] {
    return Ok(())
  }
}

// ─── NativeFlagStore (remote, feature-gated) ──────────────────────────────────

/// Remote flag store backed by an HTTP polling client.
/// Obtain one with `connectRemote()` (requires the `remote` feature).
@experimental
@cfg(feature = "remote")
pub record NativeFlagStore {
  storeHandle: Int
}

@cfg(feature = "remote")
impl FlagStore for NativeFlagStore {
  func isEnabled(name: in String): Bool {
    return Flags.Kernel.Net.isEnabled(storeHandle, name)
  }

  func getValue(name: in String): Option[FlagValue] {
    val raw = Flags.Kernel.Net.getValue(storeHandle, name)
    if raw == "" {
      return None
    }
    // Raw is a JSON-encoded FlagValue; parse the bool case for now.
    if raw == "true" {
      return Some(value = FlagValue.FlagBool(value = true))
    } else if raw == "false" {
      return Some(value = FlagValue.FlagBool(value = false))
    } else {
      return Some(value = FlagValue.FlagString(value = raw))
    }
  }

  func listFlags(): [FlagEntry] {
    // The kernel returns a JSON array; parsing deferred to Std.Json integration.
    return []
  }

  func refresh(): Result[Unit, FlagError] {
    match Flags.Kernel.Net.refresh(storeHandle) {
      case Ok(_)    -> Ok(())
      case Err(msg) -> Err(FlagError(message = msg, code = "REFRESH_ERROR"))
    }
  }
}

// ─── Config ───────────────────────────────────────────────────────────────────

/// Remote flag endpoint connection settings.
@cfg(feature = "remote")
config Remote {
  url:              String
  @sensitive
  apiKey:           String                          = ""
  pollIntervalMs:   Int range 5000 ..= 3600000      = 30000
  connectTimeoutMs: Int range 1000 ..= 30000        = 5000
  appKey:           String                          = ""
}

// ─── Factory functions ────────────────────────────────────────────────────────

/// Create an empty in-process flag store.
@stable(since="0.1")
pub func inProcess(): InProcessFlagStore {
  return InProcessFlagStore(flags = Map.empty())
}

/// Create an in-process flag store pre-loaded with the given entries.
@stable(since="0.1")
pub func fromEntries(entries: in [FlagEntry]): InProcessFlagStore {
  var m: Map[String, FlagEntry] = Map.empty()
  for entry in entries {
    m = m.set(entry.name, entry)
  }
  return InProcessFlagStore(flags = m)
}

/// Open a connection to the remote flag endpoint using the Remote config block.
/// Requires the `remote` feature to be active (`[features] remote = []`).
@stable(since="0.1")
@cfg(feature = "remote")
pub func connectRemote(): Result[FlagStore, FlagError] {
  match Flags.Kernel.Net.connect(
    Remote.url,
    Remote.apiKey,
    Remote.appKey,
    Remote.pollIntervalMs,
    Remote.connectTimeoutMs)
  {
    case Ok(handle) -> Ok(NativeFlagStore(storeHandle = handle))
    case Err(msg)   -> Err(FlagError(message = msg, code = "CONNECT_ERROR"))
  }
}

// ─── Convenience functions ────────────────────────────────────────────────────

/// Return true if the named flag is enabled in `store`.
@stable(since="0.1")
pub func isEnabled(store: in FlagStore, name: in String): Bool
  requires: name.length > 0
{
  return store.isEnabled(name)
}

/// Return the value of the named flag, or None if absent.
@stable(since="0.1")
pub func getValue(store: in FlagStore, name: in String): Option[FlagValue]
  requires: name.length > 0
{
  return store.getValue(name)
}

/// Return the Bool value of the named flag, or `defaultValue` if absent or non-Bool.
@stable(since="0.1")
pub func getBool(store: in FlagStore, name: in String, defaultValue: in Bool): Bool
  requires: name.length > 0
{
  match store.getValue(name) {
    case Some(v) ->
      match v {
        case FlagValue.FlagBool(value = b) -> b
        case FlagValue.FlagString(_)       -> defaultValue
        case FlagValue.FlagInt(_)          -> defaultValue
        case FlagValue.FlagFloat(_)        -> defaultValue
      }
    case None -> defaultValue
  }
}

/// Return the String value of the named flag, or `defaultValue` if absent or non-String.
@stable(since="0.1")
pub func getString(store: in FlagStore, name: in String, defaultValue: in String): String
  requires: name.length > 0
{
  match store.getValue(name) {
    case Some(v) ->
      match v {
        case FlagValue.FlagString(value = s) -> s
        case FlagValue.FlagBool(_)           -> defaultValue
        case FlagValue.FlagInt(_)            -> defaultValue
        case FlagValue.FlagFloat(_)          -> defaultValue
      }
    case None -> defaultValue
  }
}

/// Return the Int value of the named flag, or `defaultValue` if absent or non-Int.
@stable(since="0.1")
pub func getInt(store: in FlagStore, name: in String, defaultValue: in Int): Int
  requires: name.length > 0
{
  match store.getValue(name) {
    case Some(v) ->
      match v {
        case FlagValue.FlagInt(value = n) -> n
        case FlagValue.FlagBool(_)        -> defaultValue
        case FlagValue.FlagString(_)      -> defaultValue
        case FlagValue.FlagFloat(_)       -> defaultValue
      }
    case None -> defaultValue
  }
}

/// Refresh the flag store from the remote endpoint.
@stable(since="0.1")
pub func refresh(store: in FlagStore): Result[Unit, FlagError] {
  return store.refresh()
}

/// Construct a Bool FlagEntry with an empty description.
@stable(since="0.1")
pub func makeFlag(name: in String, enabled: in Bool): FlagEntry
  requires: name.length > 0
{
  return FlagEntry(
    name        = name,
    value       = FlagValue.FlagBool(value = enabled),
    description = "")
}

/// Construct a Bool FlagEntry with a description.
@stable(since="0.1")
pub func makeFlagWithDesc(name: in String, enabled: in Bool, description: in String): FlagEntry
  requires: name.length > 0
{
  return FlagEntry(
    name        = name,
    value       = FlagValue.FlagBool(value = enabled),
    description = description)
}

