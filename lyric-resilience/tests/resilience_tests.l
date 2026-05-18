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
