/// Flags.Kernel.Jvm — JVM extern boundary for remote feature flag store drivers.
///
/// JVM implementation of the same contract as Flags.Kernel.Net.  HTTP polling
/// uses `java.net.http.HttpClient` (JDK 11+, no external dependency required).
/// The process-global flag registry uses `lyric.flags.Registry` backed by
/// `java.util.concurrent.ConcurrentHashMap`.
///
/// Only active when compiled with feature = "jvm" (Phase 6).
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "jvm")
package Flags.Kernel.Jvm

import Std.Core

// ─── Remote HTTP polling client ───────────────────────────────────────────────

@axiom("java.net.http.HttpClient for remote feature flag polling (JDK 11+)")
@cfg(feature = "remote")
extern package lyric.flags.HttpClient {
  /// Open a polling connection to the remote flag endpoint.
  /// Returns an opaque store handle on success.
  pub func connect(
    url:             String,
    apiKey:          String,
    appKey:          String,
    pollIntervalMs:  Int,
    connectTimeoutMs: Int
  ): Result[Int, String]

  /// Return true if the named flag is enabled in the remote store.
  pub func isEnabled(storeHandle: Int, name: String): Bool

  /// Return the JSON-encoded value for the named flag, or "" if absent.
  pub func getValue(storeHandle: Int, name: String): String

  /// Return a JSON array of all flag entries in the remote store.
  pub func listFlags(storeHandle: Int): String

  /// Trigger an immediate refresh from the remote endpoint.
  pub func refresh(storeHandle: Int): Result[Unit, String]
}

// ─── Process-global flag registry ────────────────────────────────────────────

@axiom("lyric.flags.Registry backed by java.util.concurrent.ConcurrentHashMap")
extern package lyric.flags.Registry {
  /// Return the Bool value of a named flag, or `defaultValue` if absent.
  pub func checkFlag(name: String, defaultValue: Bool): Bool

  /// Return the String value of a named flag, or `defaultValue` if absent.
  pub func getStringFlag(name: String, defaultValue: String): String

  /// Register (or overwrite) a Bool flag in the process-global registry.
  pub func registerBoolFlag(name: String, value: Bool): Unit

  /// Register (or overwrite) a String flag in the process-global registry.
  pub func registerStringFlag(name: String, value: String): Unit
}

// ─── Re-exports with `in` mode ────────────────────────────────────────────────

/// Open a polling connection to the remote flag endpoint.
@cfg(feature = "remote")
pub func connect(
  url:              in String,
  apiKey:           in String,
  appKey:           in String,
  pollIntervalMs:   in Int,
  connectTimeoutMs: in Int
): Result[Int, String] {
  return lyric.flags.HttpClient.connect(url, apiKey, appKey, pollIntervalMs, connectTimeoutMs)
}

/// Return true if the named flag is enabled in the remote store.
@cfg(feature = "remote")
pub func isEnabled(storeHandle: in Int, name: in String): Bool {
  return lyric.flags.HttpClient.isEnabled(storeHandle, name)
}

/// Return the JSON-encoded value for the named flag, or "" if absent.
@cfg(feature = "remote")
pub func getValue(storeHandle: in Int, name: in String): String {
  return lyric.flags.HttpClient.getValue(storeHandle, name)
}

/// Return a JSON array of all flag entries in the remote store.
@cfg(feature = "remote")
pub func listFlags(storeHandle: in Int): String {
  return lyric.flags.HttpClient.listFlags(storeHandle)
}

/// Trigger an immediate refresh from the remote endpoint.
@cfg(feature = "remote")
pub func refresh(storeHandle: in Int): Result[Unit, String] {
  return lyric.flags.HttpClient.refresh(storeHandle)
}

/// Return the Bool value of a named flag from the process-global registry.
pub func checkFlag(name: in String, defaultValue: in Bool): Bool {
  return lyric.flags.Registry.checkFlag(name, defaultValue)
}

/// Return the String value of a named flag from the process-global registry.
pub func getStringFlag(name: in String, defaultValue: in String): String {
  return lyric.flags.Registry.getStringFlag(name, defaultValue)
}

/// Register a Bool flag in the process-global registry.
pub func registerBoolFlag(name: in String, value: in Bool): Unit {
  lyric.flags.Registry.registerBoolFlag(name, value)
}

/// Register a String flag in the process-global registry.
pub func registerStringFlag(name: in String, value: in String): Unit {
  lyric.flags.Registry.registerStringFlag(name, value)
}
