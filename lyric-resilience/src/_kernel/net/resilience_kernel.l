/// Resilience.Kernel.Net — .NET resilience extern boundary.
///
/// Provides:
///   sleepMs             — Thread.Sleep for retry backoff
///   circuitIsOpen       — query per-named circuit state (thread-safe)
///   circuitRecordSuccess — record a successful call
///   circuitRecordFailure — record a failed call; may open the circuit
///
/// Circuit state is stored in a process-global ConcurrentDictionary keyed
/// by circuit name.  Each entry tracks consecutive failures, open/closed
/// status, and the timestamp when the circuit opened.  The kernel resets
/// an open circuit to half-open after `cooldownMs` and allows one probe.
///
/// Only active when compiled with feature = "dotnet".
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Resilience.Kernel.Net

import Std.Core

@axiom("System.Threading for sleep and System.Collections.Concurrent for circuit state")
extern package System.Threading {
  /// Block the calling thread for `ms` milliseconds.  Used for retry backoff.
  pub func sleepMs(ms: Int): Unit
    requires: ms >= 0
}

@axiom("In-process circuit breaker state (ConcurrentDictionary per circuit name)")
extern package Lyric.Resilience.CircuitStore {
  /// Returns true if the named circuit is currently open (rejecting calls).
  /// Transitions an open circuit to half-open after `cooldownMs` has elapsed.
  pub func circuitIsOpen(name: String, cooldownMs: Int): Bool
    requires: name.length > 0
    requires: cooldownMs > 0

  /// Record a successful call.  Closes the circuit and resets the failure count.
  pub func circuitRecordSuccess(name: String): Unit
    requires: name.length > 0

  /// Record a failed call.  Increments the failure count and opens the circuit
  /// when the count reaches `failureThreshold`.
  pub func circuitRecordFailure(name: String, failureThreshold: Int): Unit
    requires: name.length > 0
    requires: failureThreshold > 0
}
