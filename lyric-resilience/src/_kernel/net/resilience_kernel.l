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

@axiom("System.Threading.Thread.Sleep — blocks the calling thread for the given number of milliseconds")
@externTarget("System.Threading.Thread.Sleep")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
  = ()

@axiom("Lyric.Resilience.CircuitStore.circuitIsOpen — per-process sliding-window half-open state machine in CircuitStoreHost.fs")
@externTarget("Lyric.Resilience.CircuitStore.circuitIsOpen")
pub func circuitIsOpen(name: in String, cooldownMs: in Int): Bool
  requires: name.length > 0
  requires: cooldownMs > 0
  = ()

@axiom("Lyric.Resilience.CircuitStore.circuitRecordSuccess — closes the circuit and resets the consecutive-failure count")
@externTarget("Lyric.Resilience.CircuitStore.circuitRecordSuccess")
pub func circuitRecordSuccess(name: in String): Unit
  requires: name.length > 0
  = ()

@axiom("Lyric.Resilience.CircuitStore.circuitRecordFailure — increments the failure count and opens the circuit when the threshold is reached")
@externTarget("Lyric.Resilience.CircuitStore.circuitRecordFailure")
pub func circuitRecordFailure(name: in String, failureThreshold: in Int): Unit
  requires: name.length > 0
  requires: failureThreshold > 0
  = ()
