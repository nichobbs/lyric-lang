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
import Std.Log
import Health.Kernel.Net as HealthKernelNet

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

/// A registered health check: a name, the group it belongs to, the check
/// function itself, and its execution budget in milliseconds.  The
/// handler is stored as a function reference and invoked directly by
/// `runChecks` — no reflection, no name lookup.
@stable(since = "0.1")
pub record HealthCheck {
  name: String
  group: CheckGroup
  handler: () -> CheckStatus
  timeoutMs: Int

  // Direct construction (bypassing `addLivenessCheck`/`addReadinessCheck`
  // and their `*WithTimeout` variants) is otherwise able to build a check
  // with an empty name or a `timeoutMs` that `runCheckIsolated` cannot
  // safely pass to `Task.Wait` on `--target dotnet`: `-1` means wait
  // forever there, and `-2` throws outside the isolation boundary.
  invariant: name.length > 0 and timeoutMs >= 1
}

/// The default per-check execution budget in milliseconds, used by
/// `addLivenessCheck`/`addReadinessCheck`.  Use
/// `addLivenessCheckWithTimeout`/`addReadinessCheckWithTimeout` to
/// override it for a specific check.
@stable(since = "0.1")
pub val defaultCheckTimeoutMs: Int = 5000

/// True when `timeoutMs` is actually enforced with a preemptive bound on
/// this target (`--target dotnet`, via `Health.Kernel.Net`'s real
/// `Task.Wait(int)`); false when it is validated but not enforced
/// (`--target jvm` — see `runCheckIsolated`'s `@cfg(feature = "jvm")` arm
/// and README.md "Platform parity" for why).  Exposed so callers and
/// tests can assert on the target-specific behaviour without needing
/// their own target detection.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub val timeoutEnforced: Bool = true

@stable(since = "0.1")
@cfg(feature = "jvm")
pub val timeoutEnforced: Bool = false

// ─── Registry ─────────────────────────────────────────────────────────────────
/// An immutable collection of health checks.  Build with `Health.create()`,
/// extend with `addLivenessCheck` / `addReadinessCheck`, then run with
/// `runChecks`, `runLiveness`, or `runReadiness`.
@stable(since = "0.1")
pub record HealthRegistry {
  checks: slice[HealthCheck]

  // Two checks sharing a name would collide into one JSON key in the
  // response body (module header); `hasCheckNamed`/the `add*Check`
  // functions already enforce this on the builder path, but a directly
  // constructed registry must not be able to bypass it.
  invariant: allNamesUnique(checks)
}

/// Create an empty registry.
@stable(since = "0.1")
pub func create(): HealthRegistry {
  val empty: slice[HealthCheck] = []
  return HealthRegistry(checks = empty)
}

/// True when `registry` already has a check (of either group) registered
/// under `name`.  Health-check names key the JSON response object (module
/// header), so two checks sharing a name would silently collide into one
/// JSON key; `addLivenessCheck`/`addReadinessCheck` reject that with a
/// `requires:` clause built on this helper.
@stable(since = "0.1")
@pure
pub func hasCheckNamed(registry: in HealthRegistry, name: in String): Bool {
  var i = 0
  while i < registry.checks.length {
    if registry.checks[i].name == name {
      return true
    }
    i = i + 1
  }
  return false
}

// True iff no two checks in `checks` share a name (the `HealthRegistry`
// invariant's uniqueness check). Takes the raw `slice[HealthCheck]` rather
// than a `HealthRegistry` so it can run inside that very record's own
// `invariant:` clause.
@pure
func allNamesUnique(checks: in slice[HealthCheck]): Bool {
  var i = 0
  while i < checks.length {
    var j = i + 1
    while j < checks.length {
      if checks[i].name == checks[j].name {
        return false
      }
      j = j + 1
    }
    i = i + 1
  }
  return true
}

/// Register a liveness check with the default execution budget
/// (`defaultCheckTimeoutMs`).
///
/// `handler` returns `pass()` when the process is healthy and
/// `fail(detail)` when it should be restarted.
@stable(since = "0.1")
pub func addLivenessCheck(registry: in HealthRegistry, name: in String, handler: in () -> CheckStatus): HealthRegistry
  requires: name.length > 0
  requires: not hasCheckNamed(registry, name)
{
  return addLivenessCheckWithTimeout(registry, name, handler, defaultCheckTimeoutMs)
}

/// Register a liveness check with an explicit per-check execution budget.
///
/// `handler` returns `pass()` when the process is healthy and
/// `fail(detail)` when it should be restarted.  If `handler` panics, or
/// does not return within `timeoutMs`, the check is reported unhealthy
/// with a generic message rather than propagating the panic or hanging
/// the caller (subject to `runCheckIsolated`'s per-target enforcement —
/// see its `@cfg(feature = "jvm")` arm for the one target-specific
/// limitation).
@stable(since = "0.1")
pub func addLivenessCheckWithTimeout(
  registry: in HealthRegistry,
  name: in String,
  handler: in () -> CheckStatus,
  timeoutMs: in Int,
): HealthRegistry
  requires: name.length > 0
  requires: not hasCheckNamed(registry, name)
  requires: timeoutMs >= 1
{
  val check = HealthCheck(name = name, group = Liveness, handler = handler, timeoutMs = timeoutMs)
  return HealthRegistry(checks = concat(registry.checks, [check]))
}

/// Register a readiness check with the default execution budget
/// (`defaultCheckTimeoutMs`).
///
/// `handler` returns `pass()` when the process is ready for traffic and
/// `fail(detail)` when it should be removed from the load balancer.
@stable(since = "0.1")
pub func addReadinessCheck(registry: in HealthRegistry, name: in String, handler: in () -> CheckStatus): HealthRegistry
  requires: name.length > 0
  requires: not hasCheckNamed(registry, name)
{
  return addReadinessCheckWithTimeout(registry, name, handler, defaultCheckTimeoutMs)
}

/// Register a readiness check with an explicit per-check execution
/// budget.  See `addLivenessCheckWithTimeout` for the panic/timeout
/// contract.
@stable(since = "0.1")
pub func addReadinessCheckWithTimeout(
  registry: in HealthRegistry,
  name: in String,
  handler: in () -> CheckStatus,
  timeoutMs: in Int,
): HealthRegistry
  requires: name.length > 0
  requires: not hasCheckNamed(registry, name)
  requires: timeoutMs >= 1
{
  val check = HealthCheck(name = name, group = Readiness, handler = handler, timeoutMs = timeoutMs)
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

// ─── Isolated check execution ─────────────────────────────────────────────────
// A mutable cross-thread result cell for the `--target dotnet` runner below:
// `Health.Kernel.Net.runAction`'s closure writes into it from a thread-pool
// thread, and the calling thread reads it back after `waitTask` returns.
@cfg(feature = "dotnet")
record CheckRunBox {
  var status: CheckStatus
  var panicked: Bool
  var panicMessage: String
}

// `--target dotnet`: run `check.handler` on a BCL thread-pool thread
// (`Health.Kernel.Net.runAction`, a real `Task.Run(Action)`) and block the
// calling thread for at most `check.timeoutMs` (`Health.Kernel.Net.waitTask`,
// a real `Task.Wait(int)` — returns `false` on timeout instead of throwing,
// so a hanging check genuinely stops blocking the caller after the budget
// elapses; the background action itself is left running, since neither the
// BCL nor this API has a way to forcibly abort it).  A panic inside the
// handler is caught on the background thread itself, so it never escapes as
// an unobserved faulted-task exception; the caller only ever sees the
// generic "check panicked" detail below — never the panic's own message,
// which would otherwise leak into the HTTP response body. The message is
// not discarded outright, though: it is logged server-side via `Std.Log`
// below, for operators to see without exposing it to `/health/*` callers.
@cfg(feature = "dotnet")
func runCheckIsolated(check: in HealthCheck): CheckStatus {
  val box = CheckRunBox(status = fail(""), panicked = false, panicMessage = "")
  val handler = check.handler
  val action: () -> Unit = { ->
    try {
      val result: CheckStatus = handler()
      box.status = result
    } catch Bug as b {
      box.panicked = true
      box.panicMessage = b.message
    }
  }
  val t = HealthKernelNet.runAction(action)
  val completed = HealthKernelNet.waitTask(t, check.timeoutMs)
  if not completed {
    return fail("check \"" + check.name + "\" timed out after " + ("" + check.timeoutMs) + "ms")
  }
  if box.panicked {
    error("health check \"" + check.name + "\" panicked: " + box.panicMessage)
    return fail("check panicked")
  }
  return box.status
}

// `--target jvm`: no preemptive, worker-bounded timeout is possible on this
// target with existing facilities. A Lyric closure has no bridge to any JDK
// functional interface (`Runnable`/`Callable`) outside the compiler's own
// `spawn`/`scope { }` keyword codegen — see
// lyric-stdlib/std/_kernel_jvm/task.l's module header, which documents this
// gap after empirically verifying it while building `Std.Task`'s own JVM
// kernel.  Even that keyword codegen doesn't help here: `scope { }`'s join
// is an unconditional full wait with no bounded/"whichever finishes first"
// variant, and `await` takes no timeout parameter either.  Checking elapsed
// time only *after* `handler()` returns would not actually bound the call —
// the caller would already have blocked for the full duration — so that is
// deliberately not done here; it would fake enforcement rather than provide
// it.  `check.timeoutMs` is still validated at registration (`requires:
// timeoutMs >= 1`) for cross-target API consistency, but is not enforced on
// this target: a hanging check still hangs `runLiveness`/`runReadiness` on
// `--target jvm` (#7461).  See README.md "Platform parity". Panic isolation is real
// on this target — a panicking handler is always caught here.
@cfg(feature = "jvm")
func runCheckIsolated(check: in HealthCheck): CheckStatus {
  val handler = check.handler
  try {
    val result: CheckStatus = handler()
    return result
  } catch Bug as b {
    error("health check \"" + check.name + "\" panicked: " + b.message)
    return fail("check panicked")
  }
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
      val status: CheckStatus = runCheckIsolated(check)
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
