/// Jobs.Aspects — pub aspect templates for background job cross-cutting concerns.
///
/// Two templates:
///
///   Retryable — wraps a job handler returning `Result[String, JobError]`.
///               Retries on Err with exponential backoff using
///               `Resilience.sleepMs`.
///
///   Timed     — measures handler execution time and logs a warning when the
///               elapsed time exceeds a configured threshold.
///
/// Typical consumer usage:
///
///   import Jobs.Aspects
///
///   aspect EmailRetry from Jobs.Aspects.Retryable {
///     matches: name like "sendEmail*"
///     config { maxAttempts: Int = 5, initialDelayMs: Int = 200, backoffFactor: Int = 2 }
///   }
///
///   aspect EmailTimed from Jobs.Aspects.Timed {
///     matches: name like "sendEmail*"
///     inside:  EmailRetry
///     config { warnThresholdMs: Int = 10000 }
///   }
///
/// Both aspects apply to functions returning `Result[String, JobError]`,
/// i.e. implementations of `JobHandler.handle`.
///
/// See docs/26-aspects.md §18, docs/27-aspect-libraries.md, and lyric-jobs/README.md.

@runtime_checked
package Jobs.Aspects

import Std.Core
import Resilience
import Jobs

// ─── Retryable ────────────────────────────────────────────────────────────────

/// Retry a job handler on failure with exponential backoff.
///
/// B-mode: wraps any function returning `Result[String, JobError]`.  On `Ok`
/// the result passes through immediately.  On `Err`, the call is retried up
/// to `maxAttempts` times; between each attempt the aspect sleeps for
/// `initialDelayMs × backoffFactor^(attempt-1)` milliseconds using
/// `Resilience.sleepMs`.  After all attempts are exhausted the last `Err`
/// is returned unchanged.
///
/// When `enabled` is false the call passes through without any retry logic.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled        Bool — master switch (default: true)
///   maxAttempts    Int  — total attempts including the first (default: 3)
///   initialDelayMs Int  — base delay in ms before the second attempt (default: 500)
///   backoffFactor  Int  — delay multiplier per retry (default: 2 — exponential)
@stable(since="0.1")
pub aspect Retryable {
  config {
    enabled:        Bool = true
    maxAttempts:    Int  = 3
    initialDelayMs: Int  = 500
    backoffFactor:  Int  = 2
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      ret = call.proceed()
      var attempt: Int = 1
      while attempt < maxAttempts {
        match ret {
          case Ok(_)  -> attempt = maxAttempts    // exit loop on success
          case Err(_) -> {
            val delay = retryBackoffDelay(initialDelayMs, backoffFactor, attempt - 1)
            Resilience.sleepMs(delay)
            ret     = call.proceed()
            attempt = attempt + 1
          }
        }
      }
    }
  }
}

// ─── Timed ───────────────────────────────────────────────────────────────────

/// Measure handler execution time and warn when the threshold is exceeded.
///
/// B-mode: wraps any function returning `Result[String, JobError]`.  Records
/// the start time via `Jobs.Kernel.Net.nowMs()` before calling the handler,
/// then computes elapsed time after `call.proceed()` returns.
///
/// When elapsed > `warnThresholdMs` and `enabled` is true:
///   - If the handler returned `Ok(output)`, the string " [warn: took Nms]"
///     is appended to the output so the scheduler's result log captures it.
///   - If the handler returned `Err(jobErr)`, the warning is appended to
///     `jobErr.message` so the error context is preserved.
///
/// When `enabled` is false the call passes through without any timing.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled         Bool — master switch (default: true)
///   warnThresholdMs Int  — elapsed ms above which a warning is appended (default: 5000)
@stable(since="0.1")
pub aspect Timed {
  config {
    enabled:         Bool = true
    warnThresholdMs: Int  = 5000
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val startMs = Jobs.Kernel.Net.nowMs()
      ret = call.proceed()
      val elapsedMs = Jobs.Kernel.Net.nowMs() - startMs
      if elapsedMs > warnThresholdMs {
        val warnSuffix = " [warn: took " + elapsedMs.toString() + "ms, threshold " + warnThresholdMs.toString() + "ms]"
        match ret {
          case Ok(output)  ->
            ret = Ok(output + warnSuffix)
          case Err(jobErr) ->
            ret = Err(JobError(
              message = jobErr.message + warnSuffix,
              code    = jobErr.code))
        }
      }
    }
  }
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Compute the exponential backoff delay for a given attempt index (0-based).
func retryBackoffDelay(initialDelayMs: in Int, backoffFactor: in Int, attempt: in Int): Int {
  var delay: Int = initialDelayMs
  var i:     Int = 0
  while i < attempt {
    delay = delay * backoffFactor
    i     = i + 1
  }
  return delay
}
