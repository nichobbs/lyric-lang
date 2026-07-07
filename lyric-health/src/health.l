//! Health — liveness and readiness health checks for lyric-web services.
//!
//! Checks are registered as function references (closures), the same
//! AOT-safe model as `Lambda.Direct` (docs/35-lambda-library.md §10):
//! the compiler roots each handler at the registration site, so no
//! runtime reflection or name-based dispatch is involved.  `runChecks`
//! invokes every registered handler for the requested group and
//! aggregates the outcomes into the JSON response shape below.
//!
//! Usage:
//!
//!   import Health
//!
//!   func checkDb(): CheckStatus {
//!     match Db.ping() {
//!       case Ok(_) -> return Health.pass()
//!       case Err(e) -> return Health.fail("db: " + e.message)
//!     }
//!   }
//!
//!   func buildHealth(): HealthRegistry {
//!     var health = Health.create()
//!     health = Health.addLivenessCheck(health, "self", { -> Health.pass() })
//!     health = Health.addReadinessCheck(health, "db", { -> checkDb() })
//!     return health
//!   }
//!
//!   // Web.Route handlers are (Web.Request) -> Web.Response; wrap the
//!   // Result[String, String] runLiveness/runReadiness return in a thin
//!   // adapter and register the adapter directly (a function reference,
//!   // no name-based dispatch):
//!   pub func healthLive(req: in Web.Request): Web.Response {
//!     match Health.runLiveness(buildHealth()) {
//!       case Ok(body) -> Web.json(200, body)
//!       case Err(msg) -> Web.errorResponse(Web.serviceUnavailable(msg))
//!     }
//!   }
//!
//!   pub func healthReady(req: in Web.Request): Web.Response {
//!     match Health.runReadiness(buildHealth()) {
//!       case Ok(body) -> Web.json(200, body)
//!       case Err(msg) -> Web.errorResponse(Web.serviceUnavailable(msg))
//!     }
//!   }
//!
//!   func main(): Unit {
//!     var router = Web.create()
//!     router = Web.addGet(router, "/health/live", healthLive)
//!     router = Web.addGet(router, "/health/ready", healthReady)
//!     Web.start(router)
//!   }
//!
//! Response shape (JSON):
//!   { "status": "ok" | "degraded",
//!     "checks": { "<name>": { "status": "ok" | "fail", "detail": "..." } } }
//!
//! `runLiveness` / `runReadiness` return Ok(body) with the JSON above when
//! every check passes, or Err(message) listing the failing check names otherwise.
//!
//! See docs/03-decision-log.md D057 and D099, and lyric-health/README.md.
@runtime_checked
package Health

import Std.Core
import Std.Char
import Std.Iter

// ─── Check vocabulary ─────────────────────────────────────────────────────────
/// The group a health check belongs to.
@stable(since = "0.1")
pub union CheckGroup {
  /// Always runs; a failure indicates the process should be restarted.
  case Liveness
  /// Indicates whether the process is ready to receive traffic.
  case Readiness
}

/// True when `group` is `Liveness`.  Prefer this (and `isReadiness`)
/// over matching `CheckGroup` from a consuming package: union case
/// dispatch across a restored-package boundary is not yet reliable in
/// the self-hosted backend (W0003 isinst fallback), while this helper
/// matches inside the defining assembly where dispatch is exact.
@stable(since = "0.1")
pub func isLiveness(group: in CheckGroup): Bool {
  match group {
    case Liveness -> return true
    case Readiness -> return false
  }
}

/// True when `group` is `Readiness`.  See `isLiveness` for why this
/// helper exists.
@stable(since = "0.1")
pub func isReadiness(group: in CheckGroup): Bool {
  return not isLiveness(group)
}

/// The outcome of a single health check.  Construct with `pass()` or
/// `fail(detail)` rather than building the record directly.
@stable(since = "0.1")
pub record CheckStatus {
  healthy: Bool
  detail: String
}

/// A passing check outcome.
@stable(since = "0.1")
pub func pass(): CheckStatus {
  return CheckStatus(healthy = true, detail = "")
}

/// A failing check outcome carrying a human-readable reason.
@stable(since = "0.1")
pub func fail(detail: in String): CheckStatus {
  return CheckStatus(healthy = false, detail = detail)
}

/// A registered health check: a name, the group it belongs to, and the
/// check function itself.  The handler is stored as a function reference
/// and invoked directly by `runChecks` — no reflection, no name lookup.
@stable(since = "0.1")
pub record HealthCheck {
  name: String
  group: CheckGroup
  handler: () -> CheckStatus
}

// ─── Registry ─────────────────────────────────────────────────────────────────
/// An immutable collection of health checks.  Build with `Health.create()`,
/// extend with `addLivenessCheck` / `addReadinessCheck`, then run with
/// `runChecks`, `runLiveness`, or `runReadiness`.
@stable(since = "0.1")
pub record HealthRegistry {
  checks: slice[HealthCheck]
}

/// Create an empty registry.
@stable(since = "0.1")
pub func create(): HealthRegistry {
  val empty: slice[HealthCheck] = []
  return HealthRegistry(checks = empty)
}

/// Register a liveness check.
///
/// `handler` returns `pass()` when the process is healthy and
/// `fail(detail)` when it should be restarted.
@stable(since = "0.1")
pub func addLivenessCheck(registry: in HealthRegistry, name: in String, handler: in () -> CheckStatus): HealthRegistry
  requires: name.length > 0
{
  val check = HealthCheck(name = name, group = Liveness, handler = handler)
  return HealthRegistry(checks = concat(registry.checks, [check]))
}

/// Register a readiness check.
///
/// `handler` returns `pass()` when the process is ready for traffic and
/// `fail(detail)` when it should be removed from the load balancer.
@stable(since = "0.1")
pub func addReadinessCheck(registry: in HealthRegistry, name: in String, handler: in () -> CheckStatus): HealthRegistry
  requires: name.length > 0
{
  val check = HealthCheck(name = name, group = Readiness, handler = handler)
  return HealthRegistry(checks = concat(registry.checks, [check]))
}

// ─── Running checks ───────────────────────────────────────────────────────────
/// The aggregated outcome of running one check group: whether every check
/// passed, and the JSON response body describing each check.
@stable(since = "0.1")
pub record HealthReport {
  healthy: Bool
  body: String
}

/// Run every check registered for `group` and aggregate the outcomes.
///
/// Each handler is invoked exactly once, in registration order.  The
/// report body is the JSON response shape documented in the module
/// header; `healthy` is true only when every check in the group passed.
/// A group with no registered checks reports healthy.
@stable(since = "0.1")
pub func runChecks(registry: in HealthRegistry, group: in CheckGroup): HealthReport {
  val run = runGroup(registry, group)
  return HealthReport(healthy = run.healthy, body = run.body)
}

/// Run all liveness checks and return Ok(JSON body) when healthy, or
/// Err(message) listing the failing check names when degraded.
/// The full per-check JSON is available via `runChecks` when the caller needs it.
@stable(since = "0.1")
pub func runLiveness(registry: in HealthRegistry): Result[String, String] {
  return reportToHandlerResult(registry, Liveness)
}

/// Run all readiness checks and return Ok(JSON body) when ready, or
/// Err(message) listing the failing check names when degraded.
@stable(since = "0.1")
pub func runReadiness(registry: in HealthRegistry): Result[String, String] {
  return reportToHandlerResult(registry, Readiness)
}

// ─── Private helpers ──────────────────────────────────────────────────────────
// One pass over a check group: every matching handler is invoked exactly
// once, and the pass accumulates both the JSON body and the failing-check
// name list so the ApiError mapping never re-runs handlers.
record GroupRun {
  healthy: Bool
  body: String
  failing: String
}

func runGroup(registry: in HealthRegistry, group: in CheckGroup): GroupRun {
  var allHealthy = true
  var checksJson = ""
  var failing = ""
  var first = true
  var i = 0
  while i < registry.checks.length {
    val check = registry.checks[i]
    if sameGroup(check.group, group) {
      val handler = check.handler
      val status = handler()
      if not status.healthy {
        allHealthy = false
        if failing.length > 0 {
          failing = failing + ", "
        }
        failing = failing + check.name
      }
      if not first {
        checksJson = checksJson + ","
      }
      checksJson = checksJson + "\"" + jsonEscape(check.name) + "\":" + checkJson(status)
      first = false
    }
    i = i + 1
  }
  val overall = if allHealthy { "ok" } else { "degraded" }
  val body = "{\"status\":\"" + overall + "\",\"checks\":{" + checksJson + "}}"
  return GroupRun(healthy = allHealthy, body = body, failing = failing)
}

func reportToHandlerResult(registry: in HealthRegistry, group: in CheckGroup): Result[String, String] {
  val run = runGroup(registry, group)
  if run.healthy {
    return Ok(run.body)
  }
  return Err("health checks degraded: " + run.failing)
}

func sameGroup(a: in CheckGroup, b: in CheckGroup): Bool {
  match a {
    case Liveness -> {
      match b {
        case Liveness -> return true
        case Readiness -> return false
      }
    }
    case Readiness -> {
      match b {
        case Liveness -> return false
        case Readiness -> return true
      }
    }
  }
}

func checkJson(status: in CheckStatus): String {
  if status.healthy {
    return "{\"status\":\"ok\",\"detail\":\"\"}"
  }
  return "{\"status\":\"fail\",\"detail\":\"" + jsonEscape(status.detail) + "\"}"
}

// The lowercase hex digit for a value in 0..15.
func hexDigit(n: in Int): String {
  val digits = "0123456789abcdef"
  return digits[n].toString()
}

// Escape special characters for JSON string embedding.  Per RFC 8259
// §7, every control character in U+0000..U+001F must be escaped: the
// shorthands `\b` `\f` `\n` `\r` `\t` for the five named controls, and
// the `\u00XX` six-character form for the rest.
func jsonEscape(s: in String): String {
  var buf: String = ""
  var i: Int = 0
  while i < s.length {
    val ch = s[i]
    if ch == '"' {
      buf = buf + "\\\""
    } else if ch == '\\' {
      buf = buf + "\\\\"
    } else if ch == '\u{0008}' {
      buf = buf + "\\b"
    } else if ch == '\u{000c}' {
      buf = buf + "\\f"
    } else if ch == '\n' {
      buf = buf + "\\n"
    } else if ch == '\r' {
      buf = buf + "\\r"
    } else if ch == '\t' {
      buf = buf + "\\t"
    } else if toInt(ch) < 32 {
      val code = toInt(ch)
      buf = buf + "\\u00" + hexDigit(code / 16) + hexDigit(code % 16)
    } else {
      buf = buf + ch.toString()
    }
    i = i + 1
  }
  return buf
}
