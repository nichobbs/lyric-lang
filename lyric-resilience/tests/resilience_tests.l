//! tests/resilience_tests.l — unit tests for the Resilience package's
//! circuit-breaker state functions.
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
  assertFalse(Resilience.cbStateCheckOpen(st, 1000, 1000), "fresh CircuitBreakerState must be closed")
}

test "CircuitBreakerState: failures below threshold leave state closed" {
  val st = Resilience.makeCircuitBreakerState()
  // threshold=5, only 4 failures → still closed.
  Resilience.cbStateRecordFailure(st, 5, 1000)
  Resilience.cbStateRecordFailure(st, 5, 2000)
  Resilience.cbStateRecordFailure(st, 5, 3000)
  Resilience.cbStateRecordFailure(st, 5, 4000)
  assertFalse(Resilience.cbStateCheckOpen(st, 10000, 5000), "4 failures below threshold of 5: state stays closed")
}

test "CircuitBreakerState: reaching threshold opens the state" {
  val st = Resilience.makeCircuitBreakerState()
  Resilience.cbStateRecordFailure(st, 3, 1000)
  Resilience.cbStateRecordFailure(st, 3, 2000)
  Resilience.cbStateRecordFailure(st, 3, 3000)
  // cooldown still in effect — should be open
  assertTrue(Resilience.cbStateCheckOpen(st, 10000, 3500), "3 failures at threshold of 3: state opens")
}

test "CircuitBreakerState: recordSuccess closes an open state" {
  val st = Resilience.makeCircuitBreakerState()
  Resilience.cbStateRecordFailure(st, 2, 1000)
  Resilience.cbStateRecordFailure(st, 2, 2000)
  assertTrue(Resilience.cbStateCheckOpen(st, 10000, 2500), "state must open after 2 failures (threshold 2)")
  Resilience.cbStateRecordSuccess(st)
  assertFalse(Resilience.cbStateCheckOpen(st, 10000, 3000), "state must close after recordSuccess")
}

test "CircuitBreakerState: cooldown grants exactly one probe" {
  val st = Resilience.makeCircuitBreakerState()
  Resilience.cbStateRecordFailure(st, 2, 1000)
  Resilience.cbStateRecordFailure(st, 2, 1500)
  // openedAtMs = 1500; cooldown = 1000 → past cooldown at nowMs >= 2500.
  // Before cooldown:
  assertTrue(Resilience.cbStateCheckOpen(st, 1000, 2000), "still in cooldown window: open")
  // First check past cooldown grants the probe (returns false / allow).
  assertFalse(Resilience.cbStateCheckOpen(st, 1000, 2600), "first check past cooldown grants probe")
  // Second concurrent check is blocked (probe in flight).
  assertTrue(Resilience.cbStateCheckOpen(st, 1000, 2700), "second check is blocked while probe in flight")
}

test "CircuitBreakerState: failed probe re-opens with fresh cooldown" {
  val st = Resilience.makeCircuitBreakerState()
  Resilience.cbStateRecordFailure(st, 2, 1000)
  Resilience.cbStateRecordFailure(st, 2, 1500)
  // Past cooldown → take the probe.
  assertFalse(Resilience.cbStateCheckOpen(st, 1000, 2600), "probe is allowed past cooldown")
  // Probe fails — re-open with fresh timestamp 3000.
  Resilience.cbStateRecordFailure(st, 2, 3000)
  // Cooldown restarts: should still be open at 3500 (only 500ms in).
  assertTrue(Resilience.cbStateCheckOpen(st, 1000, 3500), "failed probe re-opens with fresh cooldown")
  // Past the new cooldown: probe again.
  assertFalse(Resilience.cbStateCheckOpen(st, 1000, 4100), "after re-open cooldown, fresh probe is allowed")
}

// ─── backoffDelay ───────────────────────────────────────────────────────────
test "backoffDelay: zero jitter is exact exponential backoff" {
  assertEqualInt(Resilience.backoffDelay(100, 2, 0, 30000, 0.0f32), 100, "attempt 0: initial delay")
  assertEqualInt(Resilience.backoffDelay(100, 2, 1, 30000, 0.0f32), 200, "attempt 1: doubled")
  assertEqualInt(Resilience.backoffDelay(100, 2, 2, 30000, 0.0f32), 400, "attempt 2: doubled again")
}

test "backoffDelay: delay is capped at maxDelayMs regardless of attempt count" {
  assertEqualInt(Resilience.backoffDelay(100, 2, 20, 5000, 0.0f32), 5000, "high attempt count caps at maxDelayMs")
}

test "backoffDelay: jitter stays within the +/-jitterFraction*delay clamped range" {
  var i = 0
  while i < 50 {
    val jittered = Resilience.backoffDelay(1000, 2, 0, 30000, 0.5f32)
    // base delay is 1000; +/-50% jitter clamped to [0, maxDelayMs] gives [500, 1500].
    assertTrue(jittered >= 500, "jittered delay must not go below delay*(1-jitterFraction)")
    assertTrue(jittered <= 1500, "jittered delay must not exceed delay*(1+jitterFraction)")
    i = i + 1
  }
}

test "backoffDelay: jitter never pushes delay below zero or above maxDelayMs" {
  var i = 0
  while i < 50 {
    // jitterFraction=1.0 means the jitter range equals the delay itself, so an
    // unlucky low sample could go negative without the explicit clamp.
    val jittered = Resilience.backoffDelay(1000, 2, 0, 1200, 1.0f32)
    assertTrue(jittered >= 0, "jittered delay must never be negative")
    assertTrue(jittered <= 1200, "jittered delay must never exceed maxDelayMs")
    i = i + 1
  }
}
