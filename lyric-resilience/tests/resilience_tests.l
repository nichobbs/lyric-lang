// tests/resilience_tests.l — unit tests for the Resilience package's
// circuit-breaker state functions.

@test_module
package Resilience.ResilienceTests

import Std.Core
import Std.Testing
import Resilience

// ─── circuitIsOpen / circuitRecordFailure / circuitRecordSuccess ──────────────

test "fresh circuit: circuitIsOpen returns false" {
  // Use a unique name to avoid state leakage from other tests.
  val name = "test-fresh-circuit-a1"
  assertFalse(Resilience.circuitIsOpen(name, 30000), "fresh circuit must be closed")
}

test "record fewer than threshold failures: circuit stays closed" {
  val name = "test-below-threshold-b2"
  // threshold = 5; record 4 — circuit must stay closed.
  Resilience.circuitRecordFailure(name, 5)
  Resilience.circuitRecordFailure(name, 5)
  Resilience.circuitRecordFailure(name, 5)
  Resilience.circuitRecordFailure(name, 5)
  assertFalse(Resilience.circuitIsOpen(name, 30000), "4 failures below threshold of 5: circuit stays closed")
}

test "record exactly threshold failures: circuit opens" {
  val name = "test-at-threshold-c3"
  // threshold = 5; record 5 — circuit must open.
  Resilience.circuitRecordFailure(name, 5)
  Resilience.circuitRecordFailure(name, 5)
  Resilience.circuitRecordFailure(name, 5)
  Resilience.circuitRecordFailure(name, 5)
  Resilience.circuitRecordFailure(name, 5)
  assertTrue(Resilience.circuitIsOpen(name, 30000), "5 failures at threshold of 5: circuit must open")
}

test "circuitRecordSuccess closes an open circuit" {
  val name = "test-success-closes-d4"
  // Open the circuit.
  Resilience.circuitRecordFailure(name, 3)
  Resilience.circuitRecordFailure(name, 3)
  Resilience.circuitRecordFailure(name, 3)
  assertTrue(Resilience.circuitIsOpen(name, 30000), "circuit must be open after 3 failures (threshold 3)")
  // Record success — should close.
  Resilience.circuitRecordSuccess(name)
  assertFalse(Resilience.circuitIsOpen(name, 30000), "circuit must close after recordSuccess")
}

test "sleepMs(0) does not crash" {
  // Verify that a zero-millisecond sleep is accepted (requires: ms >= 0).
  Resilience.sleepMs(0)
  assertTrue(true, "sleepMs(0) completed without error")
}

// ─── CircuitBreakerState — formal-model unit tests (issue #365) ──────────────

test "CircuitBreakerState: fresh state is closed" {
  val st = Resilience.makeCircuitBreakerState()
  assertFalse(Resilience.cbStateCheckOpen(st, 1000, 1000),
              "fresh CircuitBreakerState must be closed")
}

test "CircuitBreakerState: failures below threshold leave state closed" {
  val st = Resilience.makeCircuitBreakerState()
  // threshold=5, only 4 failures → still closed.
  Resilience.cbStateRecordFailure(st, 5, 1000)
  Resilience.cbStateRecordFailure(st, 5, 2000)
  Resilience.cbStateRecordFailure(st, 5, 3000)
  Resilience.cbStateRecordFailure(st, 5, 4000)
  assertFalse(Resilience.cbStateCheckOpen(st, 10000, 5000),
              "4 failures below threshold of 5: state stays closed")
}

test "CircuitBreakerState: reaching threshold opens the state" {
  val st = Resilience.makeCircuitBreakerState()
  Resilience.cbStateRecordFailure(st, 3, 1000)
  Resilience.cbStateRecordFailure(st, 3, 2000)
  Resilience.cbStateRecordFailure(st, 3, 3000)
  // cooldown still in effect — should be open
  assertTrue(Resilience.cbStateCheckOpen(st, 10000, 3500),
             "3 failures at threshold of 3: state opens")
}

test "CircuitBreakerState: recordSuccess closes an open state" {
  val st = Resilience.makeCircuitBreakerState()
  Resilience.cbStateRecordFailure(st, 2, 1000)
  Resilience.cbStateRecordFailure(st, 2, 2000)
  assertTrue(Resilience.cbStateCheckOpen(st, 10000, 2500),
             "state must open after 2 failures (threshold 2)")
  Resilience.cbStateRecordSuccess(st)
  assertFalse(Resilience.cbStateCheckOpen(st, 10000, 3000),
              "state must close after recordSuccess")
}

test "CircuitBreakerState: cooldown grants exactly one probe" {
  val st = Resilience.makeCircuitBreakerState()
  Resilience.cbStateRecordFailure(st, 2, 1000)
  Resilience.cbStateRecordFailure(st, 2, 1500)
  // openedAtMs = 1500; cooldown = 1000 → past cooldown at nowMs >= 2500.
  // Before cooldown:
  assertTrue(Resilience.cbStateCheckOpen(st, 1000, 2000),
             "still in cooldown window: open")
  // First check past cooldown grants the probe (returns false / allow).
  assertFalse(Resilience.cbStateCheckOpen(st, 1000, 2600),
              "first check past cooldown grants probe")
  // Second concurrent check is blocked (probe in flight).
  assertTrue(Resilience.cbStateCheckOpen(st, 1000, 2700),
             "second check is blocked while probe in flight")
}

test "CircuitBreakerState: failed probe re-opens with fresh cooldown" {
  val st = Resilience.makeCircuitBreakerState()
  Resilience.cbStateRecordFailure(st, 2, 1000)
  Resilience.cbStateRecordFailure(st, 2, 1500)
  // Past cooldown → take the probe.
  assertFalse(Resilience.cbStateCheckOpen(st, 1000, 2600),
              "probe is allowed past cooldown")
  // Probe fails — re-open with fresh timestamp 3000.
  Resilience.cbStateRecordFailure(st, 2, 3000)
  // Cooldown restarts: should still be open at 3500 (only 500ms in).
  assertTrue(Resilience.cbStateCheckOpen(st, 1000, 3500),
             "failed probe re-opens with fresh cooldown")
  // Past the new cooldown: probe again.
  assertFalse(Resilience.cbStateCheckOpen(st, 1000, 4100),
              "after re-open cooldown, fresh probe is allowed")
}
