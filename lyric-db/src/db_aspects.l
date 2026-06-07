//! Db.Aspects — pub aspect templates for database cross-cutting concerns.
//!
//! Provides two reusable template aspects:
//!
//!   QueryLogging   — B-mode: logs every query before and after execution,
//!                    including the SQL text (truncated) and elapsed time.
//!                    Apply to handler functions that call `DbConnection.query`
//!                    or `DbConnection.execute`; the aspect wraps the whole
//!                    handler call, not individual query calls.
//!
//!   SlowQueryAlert — B-mode: logs a warning when a matched handler takes
//!                    longer than `thresholdMs` milliseconds total.
//!
//! Typical consumer usage:
//!
//!   import Db.Aspects
//!   import Std.Logging
//!
//!   aspect DbLogging from Db.Aspects.QueryLogging {
//!     matches: name like "handle*"
//!   }
//!
//!   aspect SlowDb from Db.Aspects.SlowQueryAlert {
//!     matches: name like "handle*"
//!     inside:  DbLogging
//!   }
//!
//! See docs/03-decision-log.md D056 and lyric-db/README.md.
@runtime_checked
package Db.Aspects

import Std.Core
import Std.Logging

// ─── QueryLogging ─────────────────────────────────────────────────────────────
/// Log entry and exit for every matched handler call.
///
/// B-mode: uses `call.qualifiedName` and `call.elapsed`; does not inspect
/// individual query parameters (which may contain sensitive data).
@stable(since = "0.1")
pub aspect QueryLogging {
  around(call) -> ret {
    val logger = Std.Logging.getLogger(call.modulePath)
    Std.Logging.log(logger, Std.Logging.LogLevel.Debug, "db → " + call.shortName, [])
    ret = call.proceed()
    val ms = call.elapsed.unwrapOr(0)
    Std.Logging.log(logger, Std.Logging.LogLevel.Debug, "db ← " + call.shortName + " (" + ms.toString() + "ms)", [])
  }
}

// ─── SlowQueryAlert ───────────────────────────────────────────────────────────
/// Log a warning when a matched handler's total elapsed time exceeds 500ms.
///
/// B-mode: uses `call.elapsed`; does not inspect query content.
@stable(since = "0.1")
pub aspect SlowQueryAlert {
  ensures: call.elapsed.unwrapOr(0) >= 0
  around(call) -> ret {
    ret = call.proceed()
    val ms = call.elapsed.unwrapOr(0)
    if ms > 500 {
      val logger = Std.Logging.getLogger(call.modulePath)
      Std.Logging.log(
        logger,
        Std.Logging.LogLevel.Warn,
        "slow db call: " + call.shortName + " took " + ms.toString() + "ms",
        [Std.Logging.field("handler", call.qualifiedName), Std.Logging.field("elapsedMs", ms.toString())]
      )
    }
  }
}
