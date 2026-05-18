/// Resilience — retry and circuit-breaker aspect templates.
///
/// Two pub aspect templates with no `matches:` clause; consumers bind them
/// locally with a `matches:` selector:
///
///   aspect DbRetry from Resilience.Retry {
///     matches: name like "query*" || name like "execute*"
///     config { maxAttempts: Int = 5, initialDelayMs: Int = 50 }
///   }
///
///   aspect WorkerCircuit from Resilience.CircuitBreaker {
///     matches: name in { workerTick }
///     config { failureThreshold: Int = 3, cooldownMs: Int = 60000 }
///   }
///
/// Both aspects apply to functions returning Result[T, String].
/// HTTP handlers (Result[T, ApiError]) should use Web.Aspects.HttpCircuitBreaker
/// from lyric-web, which calls the same kernel functions.
///
/// Circuit-breaker state design:
///
///   The ideal Lyric model is a protected type:
///
///     protected type CircuitBreakerState {
///       var consecutiveFailures: Int
///       var isOpen:              Bool
///       var openedAtMs:          Long
///       invariant: consecutiveFailures >= 0
///       entry recordSuccess(): Unit { consecutiveFailures = 0; isOpen = false }
///       entry recordFailure(threshold: in Int): Unit {
///         consecutiveFailures = consecutiveFailures + 1
///         if consecutiveFailures >= threshold { isOpen = true; openedAtMs = now() }
///       }
///       entry checkOpen(cooldownMs: in Int): Bool { ... }
///     }
///
///   Process-global lifetime requires a wire singleton (M5.2 stage 3+).
///   Until wire emitter support is complete, process-global state is
///   managed by the kernel (ConcurrentDictionary / ConcurrentHashMap)
///   and exposed through the functions below.  The protected type above
///   is the formal model; compile it separately to verify invariants.
///
/// See docs/26-aspects.md §18, docs/27-aspect-libraries.md, D056.

@runtime_checked
package Resilience

import Std.Core
import Std.Time
import Std.Log
import Resilience.Kernel.Net
import Resilience.Kernel.Jvm

// ─── Kernel-backed helpers (public so lyric-web can call them) ────────────────

/// Block the calling thread for `ms` milliseconds.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  Resilience.Kernel.Net.sleepMs(ms)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func sleepMs(ms: in Int): Unit
  requires: ms >= 0
{
  Resilience.Kernel.Jvm.sleepMs(ms)
}

/// True if the named circuit is currently open.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func circuitIsOpen(name: in String, cooldownMs: in Int): Bool {
  return Resilience.Kernel.Net.circuitIsOpen(name, cooldownMs)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func circuitIsOpen(name: in String, cooldownMs: in Int): Bool {
  return Resilience.Kernel.Jvm.circuitIsOpen(name, cooldownMs)
}

/// Record a successful call — closes the circuit and resets failure count.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func circuitRecordSuccess(name: in String): Unit {
  Resilience.Kernel.Net.circuitRecordSuccess(name)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func circuitRecordSuccess(name: in String): Unit {
  Resilience.Kernel.Jvm.circuitRecordSuccess(name)
}

/// Record a failed call — opens the circuit when threshold is reached.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func circuitRecordFailure(name: in String, failureThreshold: in Int): Unit {
  Resilience.Kernel.Net.circuitRecordFailure(name, failureThreshold)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func circuitRecordFailure(name: in String, failureThreshold: in Int): Unit {
  Resilience.Kernel.Jvm.circuitRecordFailure(name, failureThreshold)
}

// Private: compute exponential backoff delay with a cap and optional jitter.
// Without a cap, `initialDelayMs=100, factor=2, attempt=25` overflows Int at
// ~attempt 22 (2^22 × 100 ≈ 419 ms → 2^30 × 100 overflows Int.maxValue).
// `maxDelayMs` (default 30000 ms) prevents this and also limits thundering
// herds.  `jitterFraction` adds ±jitter×delay random jitter; 0.0 = no jitter.
func backoffDelay(
  initialDelayMs:  in Int,
  backoffFactor:   in Int,
  attempt:         in Int,
  maxDelayMs:      in Int,
  jitterFraction:  in Float
): Int {
  var delay: Int = initialDelayMs
  var i:     Int = 0
  while i < attempt {
    // Clamp before multiplying to avoid Int overflow.
    if delay >= maxDelayMs {
      delay = maxDelayMs
      i     = attempt    // early exit: already at cap
    } else {
      val next = delay * backoffFactor
      delay    = if next > maxDelayMs then maxDelayMs else next
      i        = i + 1
    }
  }
  // Apply jitter: delay × (1 ± jitterFraction).  Mixes the current time in
  // milliseconds with the attempt number so concurrent callers at the same
  // retry attempt get distinct pseudo-random values, breaking thundering herds.
  if jitterFraction > 0.0 {
    val nowSeed    = (Std.Time.monotonicNanos() mod 1000000i64).toInt()
    val pseudoRand = ((nowSeed * 1664525 + attempt * 22695477 + 1013904223) mod 1000).toFloat() / 1000.0
    val jitter = (pseudoRand * 2.0 - 1.0) * jitterFraction
    val jitteredDelay = (delay.toFloat() * (1.0 + jitter)).toInt()
    if jitteredDelay < 0 then 0 else if jitteredDelay > maxDelayMs then maxDelayMs else jitteredDelay
  } else {
    delay
  }
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
@stable(since="0.1")
pub aspect Retry {
  config {
    enabled:        Bool  = true
    maxAttempts:    Int   = 3
    initialDelayMs: Int   = 100
    backoffFactor:  Int   = 2
    maxDelayMs:     Int   = 30000
    jitterFraction: Float = 0.1
    logRetries:     Bool  = true
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      ret = call.proceed()
      var attempt: Int = 1
      while attempt < maxAttempts {
        match ret {
          case Ok(_)   -> attempt = maxAttempts    // exit: success
          case Err(msg) -> {
            if logRetries {
              Std.Log.warn("Retry: attempt " + attempt.toString() + " of " +
                           maxAttempts.toString() + " failed: " + msg)
            }
            val delay = backoffDelay(initialDelayMs, backoffFactor, attempt - 1, maxDelayMs, jitterFraction)
            Resilience.sleepMs(delay)
            ret     = call.proceed()
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
@stable(since="0.1")
pub aspect CircuitBreaker {
  config {
    enabled:          Bool   = true
    name:             String = ""
    failureThreshold: Int    = 5
    cooldownMs:       Int    = 30000
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = if name.length > 0 then name else call.qualifiedName
      if Resilience.circuitIsOpen(key, cooldownMs) {
        ret = Err("circuit open: " + key + " is temporarily unavailable")
      } else {
        ret = call.proceed()
        match ret {
          case Ok(_)  -> Resilience.circuitRecordSuccess(key)
          case Err(_) -> Resilience.circuitRecordFailure(key, failureThreshold)
        }
      }
    }
  }
}
