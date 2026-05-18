// Db.Aspects — pub aspect templates for database cross-cutting concerns.
//
// Provides two reusable template aspects:
//
//   QueryLogging   — B-mode: logs every query before and after execution,
//                    including the SQL text (truncated) and elapsed time.
//                    Apply to handler functions that call `DbConnection.query`
//                    or `DbConnection.execute`; the aspect wraps the whole
//                    handler call, not individual query calls.
//
//   SlowQueryAlert — B-mode: logs a warning when a matched handler takes
//                    longer than `thresholdMs` milliseconds total.
//
// Typical consumer usage:
//
//   import Db.Aspects
//   import Std.Logging
//
//   aspect DbLogging from Db.Aspects.QueryLogging {
//     matches: name like "handle*"
//     config { level: Std.Logging.LogLevel = Std.Logging.LogLevel.Debug }
//   }
//
//   aspect SlowDb from Db.Aspects.SlowQueryAlert {
//     matches: name like "handle*"
//     inside:  DbLogging
//     config { thresholdMs: Int = 200 }
//   }
//
// See docs/03-decision-log.md D056 and lyric-db/README.md.

@runtime_checked
package Db.Aspects

import Std.Core
import Std.Logging

// ─── QueryLogging ─────────────────────────────────────────────────────────────

/// Log entry and exit for every matched handler call.
///
/// B-mode: uses `call.qualifiedName` and `call.elapsed`; does not inspect
/// individual query parameters (which may contain sensitive data).
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled    Bool     — master switch (default: true)
///   level      LogLevel — log level for entry/exit messages (default: Debug)
///   loggerName String   — logger name; empty → uses call.modulePath (default: "")
@stable(since="0.1")
pub aspect QueryLogging {
  config {
    enabled:    Bool                      = true
    level:      Std.Logging.LogLevel      = Std.Logging.LogLevel.Debug
    loggerName: String                    = ""
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val name   = if loggerName == "" then call.modulePath else loggerName
      val logger = Std.Logging.getLogger(name)
      Std.Logging.log(logger, level, "db → " + call.shortName, [])
      ret = call.proceed()
      val ms = call.elapsed.unwrapOr(0)
      Std.Logging.log(logger, level, "db ← " + call.shortName + " (" + ms.toString() + "ms)", [])
    }
  }
}

// ─── SlowQueryAlert ───────────────────────────────────────────────────────────

/// Log a warning when a matched handler's total elapsed time exceeds the
/// configured threshold.
///
/// B-mode: uses `call.elapsed`; does not inspect query content.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled     Bool     — master switch (default: true)
///   thresholdMs Int      — warn threshold in milliseconds (default: 500)
///   alertLevel  LogLevel — log level for the alert message (default: Warn)
///   loggerName  String   — logger name; empty → uses call.modulePath (default: "")
@stable(since="0.1")
pub aspect SlowQueryAlert {
  config {
    enabled:     Bool                 = true
    thresholdMs: Int range 1 ..= 300000 = 500
    alertLevel:  Std.Logging.LogLevel = Std.Logging.LogLevel.Warn
    loggerName:  String               = ""
  }

  ensures:
    call.elapsed.unwrapOr(0) >= 0

  around(call) -> ret {
    ret = call.proceed()
    if enabled {
      val ms = call.elapsed.unwrapOr(0)
      if ms > thresholdMs {
        val name   = if loggerName == "" then call.modulePath else loggerName
        val logger = Std.Logging.getLogger(name)
        Std.Logging.log(logger, alertLevel,
          "slow db call: " + call.shortName + " took " + ms.toString() + "ms (threshold " + thresholdMs.toString() + "ms)",
          [Std.Logging.field("handler", call.qualifiedName),
           Std.Logging.field("elapsedMs", ms.toString())])
      }
    }
  }
}
