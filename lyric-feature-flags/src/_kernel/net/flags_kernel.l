// Flags.Kernel.Net — extern boundary for remote feature flag store drivers.
//
// Bridges Lyric's Flags package to .NET platform libraries:
//   Lyric.Flags.Http     — HTTP polling client for remote stores
//                          (@cfg feature = "remote")
//   Lyric.Flags.Registry — process-global flag registry for
//                          aspect use (always available)
//
// The HTTP client polls the configured endpoint on a background thread,
// updating an in-memory ConcurrentDictionary with the latest flag values.
// The concurrent registry is used by FlagGated / FlagVariant aspects that
// cannot carry a store reference through aspect config.
//
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Flags.Kernel.Net

import Std.Core

// ─── Remote HTTP polling client ───────────────────────────────────────────────

@axiom("HTTP polling client for remote feature flag stores")
@cfg(feature = "remote")
extern package Lyric.Flags.Http {
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

@axiom("Process-global flag registry backed by System.Collections.Concurrent")
extern package Lyric.Flags.Registry {
  /// Return the Bool value of a named flag, or `defaultValue` if absent.
  pub func checkFlag(name: String, defaultValue: Bool): Bool

  /// Return the String value of a named flag, or `defaultValue` if absent.
  pub func getStringFlag(name: String, defaultValue: String): String

  /// Register (or overwrite) a Bool flag in the process-global registry.
  pub func registerBoolFlag(name: String, value: Bool): Unit

  /// Register (or overwrite) a String flag in the process-global registry.
  pub func registerStringFlag(name: String, value: String): Unit
}
