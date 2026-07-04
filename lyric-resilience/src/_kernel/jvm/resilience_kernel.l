//! Resilience.Kernel.Jvm — JVM circuit-breaker and retry extern boundary.
//!
//! Provides the same contract as Resilience.Kernel.Net:
//!   sleepMs              — Thread.sleep for retry backoff
//!   circuitIsOpen        — query per-named circuit state (thread-safe)
//!   circuitRecordSuccess — record a successful call
//!   circuitRecordFailure — record a failed call; may open the circuit
//!
//! Circuit state lives in a process-global `ConcurrentHashMap` keyed by
//! circuit name (JVM generics erase away, so the map is used as its raw
//! type via ordinary auto-FFI — no @externTarget-style generic-member
//! emission is needed, unlike the .NET kernel's ConcurrentDictionary`2
//! binding). Each entry carries its own `ReentrantLock` (the JVM has no
//! callable Monitor.Enter/Exit equivalent to the .NET kernel's — object
//! monitors are only reachable via the `synchronized` keyword, which
//! Lyric source cannot express — so an explicit per-entry lock replaces
//! it) guarding atomic read-modify-write of the four mutable fields.
//!
//! The half-open state machine mirrors Resilience.Kernel.Net exactly
//! (same state-machine invariants: consecutiveFailures >= 0; isOpen ==>
//! openedAtMs > 0) and is covered by the same CircuitBreakerState
//! formal-model tests in lyric-resilience/tests/resilience_tests.l.
//!
//! Only active when compiled with feature = "jvm".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "jvm")
package Resilience.Kernel.Jvm

import Std.Core
import Std.Time

extern type JConcurrentHashMap = "java.util.concurrent.ConcurrentHashMap"

extern type JReentrantLock = "java.util.concurrent.locks.ReentrantLock"

extern type JThread = "java.lang.Thread"

record CircuitEntry {
  var consecutiveFailures: Int = 0
  var isOpen: Bool = false
  var openedAtMs: Long = 0i64
  var halfOpenProbeInFlight: Bool = false
  lock: JReentrantLock
}

val circuitRegistry: JConcurrentHashMap = JConcurrentHashMap.new()

// `putIfAbsent` is atomic, so a race between two callers creating the same
// circuit's first entry resolves to a single winner (the entry actually
// stored in the map) rather than two independent, inconsistent instances.
func createAndRegisterEntry(name: in String): CircuitEntry {
  val fresh = CircuitEntry(
    consecutiveFailures = 0,
    isOpen = false,
    openedAtMs = 0i64,
    halfOpenProbeInFlight = false,
    lock = JReentrantLock.new()
  )
  val prior = circuitRegistry.putIfAbsent(name, fresh)
  val winner: CircuitEntry = prior ?? fresh
  winner
}

func getOrCreateEntry(name: in String): CircuitEntry {
  val existing = circuitRegistry.get(name)
  val entry: CircuitEntry = existing ?? createAndRegisterEntry(name)
  entry
}

pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  JThread.sleep(ms.toLong())
}

@stable(since = "0.1")
pub func circuitIsOpen(name: in String, cooldownMs: in Int): Bool
  requires: name.length > 0
  requires: cooldownMs > 0
{
  val entry = getOrCreateEntry(name)
  entry.lock.lock()
  defer {
    entry.lock.unlock()
  }
  if not entry.isOpen {
    return false
  }
  val elapsed: Long = nowEpochMillis() - entry.openedAtMs
  if elapsed < cooldownMs.toLong() {
    return true
  }
  if entry.halfOpenProbeInFlight {
    return true
  }
  entry.halfOpenProbeInFlight = true
  false
}

@stable(since = "0.1")
pub func circuitRecordSuccess(name: in String): Unit
  requires: name.length > 0
{
  val entry = getOrCreateEntry(name)
  entry.lock.lock()
  defer {
    entry.lock.unlock()
  }
  entry.consecutiveFailures = 0
  entry.isOpen = false
  entry.openedAtMs = 0i64
  entry.halfOpenProbeInFlight = false
}

@stable(since = "0.1")
pub func circuitRecordFailure(name: in String, failureThreshold: in Int): Unit
  requires: name.length > 0
  requires: failureThreshold > 0
{
  val entry = getOrCreateEntry(name)
  entry.lock.lock()
  defer {
    entry.lock.unlock()
  }
  entry.consecutiveFailures = entry.consecutiveFailures + 1
  if entry.isOpen {
    entry.openedAtMs = nowEpochMillis()
    entry.halfOpenProbeInFlight = false
  } else {
    if entry.consecutiveFailures >= failureThreshold {
      entry.isOpen = true
      entry.openedAtMs = nowEpochMillis()
      entry.halfOpenProbeInFlight = false
    }
  }
}
