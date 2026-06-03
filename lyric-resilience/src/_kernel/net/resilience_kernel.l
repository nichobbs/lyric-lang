// Resilience.Kernel.Net — .NET resilience extern boundary.
//
// Provides:
//   sleepMs             — Thread.Sleep for retry backoff
//   circuitIsOpen       — query per-named circuit state (thread-safe)
//   circuitRecordSuccess — record a successful call
//   circuitRecordFailure — record a failed call; may open the circuit
//
// Circuit state lives in a process-global ConcurrentDictionary keyed by
// circuit name.  The state machine is the in-process realization of the
// formal model `pub protected type CircuitBreakerState` declared in
// `lyric-resilience/src/resilience.l` (issue #365); the host class
// `Lyric.Resilience.CircuitStore` in `bootstrap/src/Lyric.Emitter/
// CircuitStoreHost.fs` mirrors the protected type's three entries and
// must keep the same invariants:
//   - consecutiveFailures >= 0
//   - isOpen ==> openedAtMs > 0
//
// The F# shim is an interim runtime: once non-constant module-level
// vals (M5.2 stage 3+) and the wire singleton emitter ship, the
// protected type can own the registry too and the shim retires.
//
// Only active when compiled with feature = "dotnet".
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Resilience.Kernel.Net

import Std.Core

@axiom("System.Threading for sleep and System.Collections.Concurrent for circuit state")
extern package System.Threading {
  /// Block the calling thread for `ms` milliseconds.  Used for retry backoff.
  pub func sleepMs(ms: Int): Unit
    requires: ms >= 0
}

@axiom("In-process circuit-breaker state machine implemented in F# at bootstrap/src/Lyric.Emitter/CircuitStoreHost.fs as Lyric.Resilience.CircuitStore; mirrors the protected-type model in lyric-resilience/src/resilience.l (issue #365)")
extern package Lyric.Resilience.CircuitStore {
  /// Returns true if the named circuit is currently open (rejecting calls).
  /// When the circuit is open and `cooldownMs` has elapsed since the last
  /// open, the first caller is granted a half-open probe (returns false);
  /// concurrent callers continue to see true until the probe records its
  /// outcome via circuitRecordSuccess or circuitRecordFailure.
  pub func circuitIsOpen(name: String, cooldownMs: Int): Bool
    requires: name.length > 0
    requires: cooldownMs > 0

  /// Record a successful call.  Closes the circuit and resets the failure count.
  pub func circuitRecordSuccess(name: String): Unit
    requires: name.length > 0

  /// Record a failed call.  Increments the failure count and opens the circuit
  /// when the count reaches `failureThreshold`.  When the circuit is already
  /// open (a half-open probe failed), refreshes `openedAtMs` so the cooldown
  /// window restarts.
  pub func circuitRecordFailure(name: String, failureThreshold: Int): Unit
    requires: name.length > 0
    requires: failureThreshold > 0
}
