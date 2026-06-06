//! Resilience.Kernel.Net — .NET circuit-breaker and retry extern boundary.
//!
//! Provides:
//!   sleepMs              — Thread.Sleep for retry backoff
//!   circuitIsOpen        — query per-named circuit state (thread-safe)
//!   circuitRecordSuccess — record a successful call
//!   circuitRecordFailure — record a failed call; may open the circuit
//!
//! Circuit state lives in a process-global ConcurrentDictionary keyed by
//! circuit name.  Per-entry Monitor locking ensures atomic read-modify-write
//! for the four mutable fields of CircuitEntry.  State-machine invariants:
//!   - consecutiveFailures >= 0
//!   - isOpen ==> openedAtMs > 0
//!
//! The half-open state machine is covered exhaustively by the
//! CircuitBreakerState formal-model tests in lyric-resilience/tests/
//! resilience_tests.l, which inject nowMs to keep tests deterministic.
//!
//! Only active when compiled with feature = "dotnet".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package Resilience.Kernel.Net

import Std.Core
import Std.Time

extern type ConcurrentDict[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDict[K, V](): ConcurrentDict[K, V] = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool = ()

record CircuitEntry {
  var consecutiveFailures: Int = 0
  var isOpen: Bool = false
  var openedAtMs: Long = 0i64
  var halfOpenProbeInFlight: Bool = false
}

@axiom("System.Threading.Monitor.Enter — acquires an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@axiom("System.Threading.Monitor.Exit — releases an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

val circuitRegistry: ConcurrentDict[String, CircuitEntry] = newConcurrentDict()

func getOrCreateEntry(name: in String): CircuitEntry {
  var found: CircuitEntry = default()
  if cdTryGetValue(circuitRegistry, name, found) {
    return found
  }
  val newEntry = CircuitEntry(consecutiveFailures = 0, isOpen = false, openedAtMs = 0i64, halfOpenProbeInFlight = false)
  val _ = cdTryAdd(circuitRegistry, name, newEntry)
  var found2: CircuitEntry = default()
  if cdTryGetValue(circuitRegistry, name, found2) {
    return found2
  }
  // Invariant: unreachable — circuitRegistry is append-only (no Remove/Clear calls),
  // so a key added via TryAdd is always present for the immediately following
  // TryGetValue.  The fallback returns newEntry to satisfy the type checker; any
  // caller that somehow reaches this path will operate on an unregistered
  // CircuitEntry (mutations will be invisible to other callers), which would
  // indicate a ConcurrentDictionary contract violation outside our control.
  newEntry
}

@axiom("System.Threading.Thread.Sleep — blocks the calling thread for the given number of milliseconds")
@externTarget("System.Threading.Thread.Sleep")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
  = ()

pub func circuitIsOpen(name: in String, cooldownMs: in Int): Bool
  requires: name.length > 0
  requires: cooldownMs > 0
{
  val circuit = getOrCreateEntry(name)
  monitorEnter(circuit)
  defer {
    monitorExit(circuit)
  }
  if not circuit.isOpen {
    return false
  }
  val elapsed: Long = nowEpochMillis() - circuit.openedAtMs
  if elapsed < cooldownMs.toLong() {
    return true
  }
  if circuit.halfOpenProbeInFlight {
    return true
  }
  circuit.halfOpenProbeInFlight = true
  false
}

pub func circuitRecordSuccess(name: in String): Unit
  requires: name.length > 0
{
  val circuit = getOrCreateEntry(name)
  monitorEnter(circuit)
  defer {
    monitorExit(circuit)
  }
  circuit.consecutiveFailures = 0
  circuit.isOpen = false
  circuit.openedAtMs = 0i64
  circuit.halfOpenProbeInFlight = false
}

pub func circuitRecordFailure(name: in String, failureThreshold: in Int): Unit
  requires: name.length > 0
  requires: failureThreshold > 0
{
  val circuit = getOrCreateEntry(name)
  monitorEnter(circuit)
  defer {
    monitorExit(circuit)
  }
  circuit.consecutiveFailures = circuit.consecutiveFailures + 1
  if circuit.isOpen {
    circuit.openedAtMs = nowEpochMillis()
    circuit.halfOpenProbeInFlight = false
  } else {
    if circuit.consecutiveFailures >= failureThreshold {
      circuit.isOpen = true
      circuit.openedAtMs = nowEpochMillis()
      circuit.halfOpenProbeInFlight = false
    }
  }
}
