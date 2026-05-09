/// Std.Logging.Aspects — aspect templates for automatic call instrumentation.
///
/// Provides three pub aspect templates consumers bind with a local matches:
/// clause.  All three use Std.Logging for output, so the global level filter
/// (LYRIC_CONFIG_STD_LOGGING_DEFAULTS_LEVEL) applies.
///
/// Templates:
///   CallLogging       — logs function entry / exit with elapsed time (B-mode)
///   SlowCallAlert     — logs a warning when a call exceeds a threshold (B-mode)
///   ErrorResultLogging — logs when a function returns Err(...) (C-mode, @inline_template)
///
/// Typical consumer instantiation:
///
///   import Std.Logging.Aspects
///
///   aspect ApiLogging from Std.Logging.Aspects.CallLogging {
///     matches: name like "handle*"
///     config {
///       level: LogLevel = LogLevel.Info
///     }
///   }
///
///   aspect ApiSlowAlert from Std.Logging.Aspects.SlowCallAlert {
///     matches: name like "handle*"
///     inside: ApiLogging
///     config {
///       thresholdMs: Int = 500
///     }
///   }
///
/// See docs/26-aspects.md §18, docs/27-aspect-libraries.md.

@runtime_checked
package Std.Logging.Aspects

import Std.Core
import Std.Logging

// ─── CallLogging ─────────────────────────────────────────────────────────────

/// Log function entry and exit for every matched call.
///
/// On entry emits: "→ <shortName>"
/// On exit  emits: "← <shortName> (<elapsed>ms)"
///
/// Both messages go through Std.Logging, so Defaults.level filters them.
/// The aspect's own config.level controls what level they are logged at;
/// setting config.level to something below Defaults.level silences the aspect.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled    Bool     — master switch; false skips all logging (default: true)
///   level      LogLevel — severity of the entry/exit messages (default: Debug)
///   loggerName String   — logger name to use; if empty, call.modulePath is used
///                         (default: "")
@stable(since="0.1")
pub aspect CallLogging {
  config {
    enabled:    Bool     = true
    level:      LogLevel = LogLevel.Debug
    loggerName: String   = ""
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      var logName = call.modulePath
      if loggerName != "" {
        logName = loggerName
      }
      val logger = Std.Logging.getLogger(logName)
      Std.Logging.logMsg(logger, level, "→ " + call.shortName)
      ret = call.proceed()
      val ms = call.elapsed.unwrapOr(0)
      Std.Logging.logMsg(logger, level, "← " + call.shortName + " (" + ms.toString() + "ms)")
    }
  }
}

// ─── SlowCallAlert ───────────────────────────────────────────────────────────

/// Log a warning when a call exceeds a configurable latency threshold.
///
/// Proceeds unconditionally; only emits a record when elapsed > thresholdMs.
/// Useful as a lightweight SLO guard when you want observability without
/// tracing every call.
///
/// The ensures: clause asserts that elapsed is non-negative — a trivially
/// true invariant that surfaces the measurement in the composed contract so
/// the verifier can propagate it to callers that care about latency bounds.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled     Bool     — master switch (default: true)
///   thresholdMs Int      — alert when elapsed exceeds this value in ms (default: 1000)
///   alertLevel  LogLevel — level of the alert record (default: Warn)
///   loggerName  String   — logger name; if empty, call.modulePath is used (default: "")
@stable(since="0.1")
pub aspect SlowCallAlert {
  config {
    enabled:     Bool     = true
    thresholdMs: Int      = 1000
    alertLevel:  LogLevel = LogLevel.Warn
    loggerName:  String   = ""
  }

  ensures:
    call.elapsed.unwrapOr(0) >= 0

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      ret = call.proceed()
      val ms = call.elapsed.unwrapOr(0)
      if ms > thresholdMs {
        var logName = call.modulePath
        if loggerName != "" {
          logName = loggerName
        }
        val logger = Std.Logging.getLogger(logName)
        Std.Logging.logMsg(logger, alertLevel,
          "SLOW: " + call.shortName + " took " + ms.toString() + "ms" +
          " (threshold: " + thresholdMs.toString() + "ms)")
      }
    }
  }
}

// ─── ErrorResultLogging ──────────────────────────────────────────────────────

/// Log when a matched function returns Err(...).
///
/// This is a C-mode template (@inline_template): the body is re-compiled
/// inside the consumer's package so it can read ret.isErr directly.
/// Apply only to functions whose return type is Result[T, E]; the consumer's
/// compiler reports a shape error otherwise.
///
/// On Err the record reads: "ERROR: <shortName> failed after <elapsed>ms"
/// Successes (Ok) produce no output.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled    Bool     — master switch (default: true)
///   level      LogLevel — severity of the error record (default: Error)
///   loggerName String   — logger name; if empty, call.modulePath is used (default: "")
@stable(since="0.1")
@inline_template
pub aspect ErrorResultLogging {
  config {
    enabled:    Bool     = true
    level:      LogLevel = LogLevel.Error
    loggerName: String   = ""
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      ret = call.proceed()
      if ret.isErr {
        val ms = call.elapsed.unwrapOr(0)
        var logName = call.modulePath
        if loggerName != "" {
          logName = loggerName
        }
        val logger = Std.Logging.getLogger(logName)
        Std.Logging.logMsg(logger, level,
          "ERROR: " + call.shortName + " failed after " + ms.toString() + "ms")
      }
    }
  }
}
