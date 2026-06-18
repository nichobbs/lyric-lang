//! Resilience — retry and circuit-breaker aspect templates.
//! Stability: @experimental — the Retry and CircuitBreaker aspect templates
//! compile and have unit tests, but their end-to-end behaviour under load has
//! not been exercised in CI.
//!
//! Two pub aspect templates with no `matches:` clause; consumers bind them
//! locally with a `matches:` selector:
//!
//!   aspect DbRetry from Resilience.Retry {
//!     matches: name like "query*" || name like "execute*"
//!     config { maxAttempts: Int = 5, initialDelayMs: Int = 50 }
//!   }
//!
//!   aspect WorkerCircuit from Resilience.CircuitBreaker {
//!     matches: name in { workerTick }
//!     config { failureThreshold: Int = 3, cooldownMs: Int = 60000 }
//!   }
//!
//! Both aspects apply to functions returning Result[T, String].
//! HTTP handlers (Result[T, ApiError]) should use Web.Aspects.HttpCircuitBreaker
//! from lyric-web, which calls the same kernel functions.
//!
//! Circuit-breaker state design:
//!
//!   The formal state machine lives below as `pub protected type
//!   CircuitBreakerState`.  Its invariants (`consecutiveFailures >= 0`,
//!   `isOpen ==> openedAtMs > 0`) are verifier-visible; its entries
//!   document the full transition system.  An instance can be exercised
//!   directly by tests via `makeCircuitBreakerState()` and the three
//!   `cbState*` helpers, with `nowMs` injected so transitions are
//!   deterministic without a real clock.
//!
//!   The aspect's runtime path goes through the process-global registry
//!   exposed by `Resilience.Kernel.Net.{circuitIsOpen, circuitRecordSuccess,
//!   circuitRecordFailure}`.  The registry is implemented in pure Lyric in
//!   `lyric-resilience/src/_kernel/net/resilience_kernel.l` using a
//!   process-global ConcurrentDictionary of CircuitEntry records with
//!   per-entry Monitor locking — matching the state-machine invariants
//!   declared on the CircuitBreakerState protected type below.
//!
//! See docs/26-aspects.md §18, docs/27-aspect-libraries.md, D056.
@runtime_checked
package Resilience

import Std.Core
import Std.Time
import Std.Log
import Resilience.Kernel.Net as ResKernelNet
import Resilience.Kernel.Jvm as ResKernelJvm

// ─── Kernel-backed helpers (public so lyric-web can call them) ────────────────
/// Block the calling thread for `ms` milliseconds.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  ResKernelNet.sleepMs(ms)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  ResKernelJvm.sleepMs(ms)
}

/// True if the named circuit is currently open.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func circuitIsOpen(name: in String, cooldownMs: in Int): Bool {
  return ResKernelNet.circuitIsOpen(name, cooldownMs)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func circuitIsOpen(name: in String, cooldownMs: in Int): Bool {
  return ResKernelJvm.circuitIsOpen(name, cooldownMs)
}

/// Record a successful call — closes the circuit and resets failure count.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func circuitRecordSuccess(name: in String): Unit {
  ResKernelNet.circuitRecordSuccess(name)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func circuitRecordSuccess(name: in String): Unit {
  ResKernelJvm.circuitRecordSuccess(name)
}

/// Record a failed call — opens the circuit when threshold is reached.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func circuitRecordFailure(name: in String, failureThreshold: in Int): Unit {
  ResKernelNet.circuitRecordFailure(name, failureThreshold)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func circuitRecordFailure(name: in String, failureThreshold: in Int): Unit {
  ResKernelJvm.circuitRecordFailure(name, failureThreshold)
}

// ─── CircuitBreakerState — formal state machine for one circuit ──────────────
//
// The verifier-visible source of truth for the circuit-breaker
// semantics that lyric-web and lyric-grpc rely on.  An instance carries
// the four-field state for exactly one circuit; the process-global
// per-name registry lives in the kernel (see `Resilience.Kernel.Net`)
// and consults this type one entry at a time.
//
// Invariants (carried as `invariant:` clauses and verifier-checkable):
//   consecutiveFailures >= 0
//   isOpen ==> openedAtMs > 0
//
// `nowMs` is injected as a parameter rather than read from a clock so
// callers can test the state machine deterministically.  The kernel
// passes the real wall clock; tests pass a counter.
//
// Issue #365: this type was previously commented-out documentation
// only.  Promoting it to a real protected type makes the semantics
// verifiable and gives users a Lyric-side handle for unit testing the
// state machine without standing up the process-global registry.
@stable(since = "0.1")
pub protected type CircuitBreakerState {
  var consecutiveFailures: Int = 0
  var isOpen: Bool = false
  var openedAtMs: Long = 0
  var halfOpenProbeInFlight: Bool = false
  invariant: consecutiveFailures >= 0
  invariant: isOpen or openedAtMs == 0
  invariant: not isOpen or openedAtMs > 0
  entry recordSuccess(): Unit {
    consecutiveFailures = 0
    isOpen = false
    openedAtMs = 0
    halfOpenProbeInFlight = false
  }
  entry recordFailure(threshold: in Int, nowMs: in Long): Unit
    requires: threshold > 0
    requires: nowMs > 0
  {
    consecutiveFailures = consecutiveFailures + 1
    if isOpen {
      // Half-open probe failed — re-open with a fresh cooldown.
      openedAtMs = nowMs
      halfOpenProbeInFlight = false
    } else {
      if consecutiveFailures >= threshold {
        isOpen = true
        openedAtMs = nowMs
        halfOpenProbeInFlight = false
      }
    }
  }
  entry checkOpen(cooldownMs: in Long, nowMs: in Long): Bool
    requires: cooldownMs > 0
    requires: nowMs > 0
  {
    if not isOpen {
      return false
    }
    val elapsed = nowMs - openedAtMs
    if elapsed < cooldownMs {
      return true
    }
    if halfOpenProbeInFlight {
      return true
    }
    halfOpenProbeInFlight = true
    return false
  }
  func snapshotIsOpen(): Bool {
    return isOpen
  }
  func snapshotConsecutiveFailures(): Int {
    return consecutiveFailures
  }
  func snapshotOpenedAtMs(): Long {
    return openedAtMs
  }
  func snapshotHalfOpenProbeInFlight(): Bool {
    return halfOpenProbeInFlight
  }
}

/// Construct a fresh, closed circuit breaker state.
@stable(since = "0.1")
pub func makeCircuitBreakerState(): CircuitBreakerState {
  return CircuitBreakerState()
}

/// Record a success against a `CircuitBreakerState` instance.  Resets
/// the failure counter and closes the circuit; idempotent.
@stable(since = "0.1")
pub func cbStateRecordSuccess(s: in CircuitBreakerState): Unit {
  s.recordSuccess()
}

/// Record a failure against a `CircuitBreakerState` instance.  Pass
/// the current time as `nowMs` so the state machine remains
/// deterministic under test.
@stable(since = "0.1")
pub func cbStateRecordFailure(s: in CircuitBreakerState, threshold: in Int, nowMs: in Long): Unit {
  s.recordFailure(threshold, nowMs)
}

/// True if the circuit is currently rejecting calls.  When the circuit
/// is open and `cooldownMs` has elapsed since `openedAtMs`, the first
/// caller is granted the half-open probe (returns false) and subsequent
/// callers continue to see true until the probe records its outcome.
@stable(since = "0.1")
pub func cbStateCheckOpen(s: in CircuitBreakerState, cooldownMs: in Long, nowMs: in Long): Bool {
  return s.checkOpen(cooldownMs, nowMs)
}

// Private: compute exponential backoff delay with a cap and optional jitter.
// Without a cap, `initialDelayMs=100, factor=2, attempt=25` overflows Int at
// ~attempt 22 (2^22 × 100 ≈ 419 ms → 2^30 × 100 overflows Int.maxValue).
// `maxDelayMs` (default 30000 ms) prevents this and also limits thundering
// herds.  `jitterFraction` adds ±jitter×delay random jitter; 0.0 = no jitter.
// `jitterFraction` is accepted for API compatibility but not applied in this
// implementation (deterministic jitter requires float arithmetic not yet
// available in the bootstrap emitter).
func backoffDelay(
  initialDelayMs: in Int,
  backoffFactor: in Int,
  attempt: in Int,
  maxDelayMs: in Int,
  jitterFraction: in Float,
): Int {
  var delay: Int = initialDelayMs
  var i: Int = 0
  while i < attempt {
    if delay >= maxDelayMs {
      delay = maxDelayMs
      i = attempt
    } else {
      val next = delay * backoffFactor
      delay = if next > maxDelayMs then maxDelayMs else next
      i = i + 1
    }
  }
  // jitterFraction is accepted for API compatibility but not applied here;
  // deterministic jitter requires float arithmetic not yet available in the bootstrap emitter.
  delay
}

// ─── Retry ────────────────────────────────────────────────────────────────────
/// Retry a function call on Err, with exponential backoff.
///
/// Applies to functions returning Result[T, String].
/// On Ok the result is returned immediately.  On Err the call is retried
/// up to `maxAttempts` times, sleeping for `initialDelayMs × backoffFactor^attempt`
/// milliseconds between tries (capped at `maxDelayMs`).  After all attempts
/// are exhausted the last Err is returned.
///
/// Config:
///   enabled         Bool  — master switch; false passes through unchanged (default: true)
///   maxAttempts     Int   — total attempts including the first (default: 3)
///   initialDelayMs  Int   — base delay in ms before the second attempt (default: 100)
///   backoffFactor   Int   — delay multiplier per retry (default: 2 — exponential)
///   maxDelayMs      Int   — upper bound on inter-retry delay (default: 30000)
///   jitterFraction  Float — fraction of delay to add as ±jitter; 0.0 = no jitter (default: 0.1)
///   logRetries      Bool  — log each failed attempt at warn level (default: true)
///
/// WARNING (information disclosure): when `logRetries` is true the raw
/// `Err` message is written to the log aggregator verbatim.  Functions
/// that may return credentials, tokens, or PII inside `Err` values
/// should either set `logRetries: false` at the call site, or sanitise
/// their error messages before returning.  See lyric-lang #602.
@stable(since = "0.1")
pub aspect Retry {
  config {
    enabled: Bool = true
    maxAttempts: Int = 3
    initialDelayMs: Int = 100
    backoffFactor: Int = 2
    maxDelayMs: Int = 30000
    jitterFraction: Float = 0.1
    logRetries: Bool = true
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      ret = call.proceed()
      var attempt: Int = 1
      while attempt < maxAttempts {
        match ret {
          case Ok(_) -> {
            attempt = maxAttempts
          }    // exit: success
          case Err(msg) -> {
            if logRetries {
              Std.Log.warn("Retry: attempt " + attempt.toString() + " of " + maxAttempts.toString() + " failed: " + msg)
            }
            val delay = backoffDelay(initialDelayMs, backoffFactor, attempt - 1, maxDelayMs, jitterFraction)
            sleepMs(delay)
            ret = call.proceed()
            attempt = attempt + 1
          }
        }
      }
    }
  }
}

// ─── CircuitBreaker ───────────────────────────────────────────────────────────
/// Open a circuit after consecutive failures; recover after a cooldown.
///
/// Applies to functions returning Result[T, String].
/// HTTP handlers should use Web.Aspects.HttpCircuitBreaker instead.
///
/// When the circuit is open, calls are short-circuited with
/// Err("circuit open: <name>") without invoking the underlying function.
/// After `cooldownMs` the circuit transitions to half-open and allows one
/// probe call through.  A successful probe closes the circuit.
///
/// Config:
///   enabled          Bool   — master switch (default: true)
///   name             String — circuit name; defaults to call.qualifiedName
///   failureThreshold Int    — consecutive failures before opening (default: 5)
///   cooldownMs       Int    — ms to wait before probing again (default: 30000)
@stable(since = "0.1")
pub aspect CircuitBreaker {
  config {
    enabled: Bool = true
    name: String = ""
    failureThreshold: Int = 5
    cooldownMs: Int = 30000
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = if name.length > 0 then name else call.qualifiedName
      if circuitIsOpen(key, cooldownMs) {
        ret = Err("circuit open: " + key + " is temporarily unavailable")
      } else {
        ret = call.proceed()
        match ret {
          case Ok(_) -> circuitRecordSuccess(key)
          case Err(_) -> circuitRecordFailure(key, failureThreshold)
        }
      }
    }
  }
}
