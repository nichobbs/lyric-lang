// Health — liveness and readiness health-check endpoints for lyric-web services.
//
// Stability: @experimental — the registry API compiles and shape-tests
// pass, but the kernel dispatcher that actually invokes registered
// check functions has not landed yet.  `runChecks` panics rather than
// silently reporting "ok" so that production callers cannot accidentally
// ship a service whose health endpoints fail to exercise the registered
// checks.  WARNING: experimental — once the dispatcher lands, the
// `__handleLiveness` / `__handleReadiness` exit point and the `runChecks`
// internal will change shape.
//
// Registers `/health/live` and `/health/ready` routes on a `Router`.
// Check functions are stored in a `HealthRegistry` value and run on each
// request to the corresponding endpoint.
//
// Usage:
//
//   import Health
//   import Web
//
//   func checkDb(conn: in DbConnection): Result[Unit, String] {
//     match conn.execute("SELECT 1", []) {
//       case Ok(_) -> Ok(())
//       case Err(e) -> Err("db: " + e.message)
//     }
//   }
//
//   func main(): Unit {
//     var router = Web.create()
//     router = addGet(router, "/users/{id}", "MyService.Handlers.getUser")
//
//     var health = Health.create()
//     health = Health.addReadinessCheck(health, "db", "MyService.checkDb")
//     router = Health.registerRoutes(router, health)
//
//     Web.start(router)
//   }
//
// Response shape (JSON):
//   { "status": "ok" | "degraded",
//     "checks": { "<name>": { "status": "ok" | "fail", "detail": "..." } } }
//
// Runtime config env vars (LYRIC_CONFIG_HEALTH_ENDPOINTS_*):
//   LYRIC_CONFIG_HEALTH_ENDPOINTS_LIVEPATH   — liveness path  (default: /health/live)
//   LYRIC_CONFIG_HEALTH_ENDPOINTS_READYPATH  — readiness path (default: /health/ready)
//
// See docs/03-decision-log.md D057 and lyric-health/README.md.

@runtime_checked
package Health

import Std.Core
import Std.Iter
import Web

// ─── Check descriptor ─────────────────────────────────────────────────────────

/// The group a health check belongs to.
@stable(since="0.1")
pub enum CheckGroup {
  case Liveness    // always runs; indicates whether the process should be killed
  case Readiness   // indicates whether the process is ready to receive traffic
}

/// A registered health check: a name, the group it belongs to, and the
/// fully-qualified name of the check function.
///
/// The check function must have signature `(): Result[Unit, String]`.
/// The kernel resolves it via DLL reflection when the health endpoint is hit,
/// matching the same dispatch model as `Web.Route.handlerName`.
@stable(since="0.1")
pub record HealthCheck {
  name:        String
  group:       CheckGroup
  handlerName: String    // fully-qualified Lyric function name
}

// ─── Registry ─────────────────────────────────────────────────────────────────

/// An immutable collection of health checks.  Build with `Health.create()`,
/// extend with `addLivenessCheck` / `addReadinessCheck`, then call
/// `Health.registerRoutes(router, registry)`.
@stable(since="0.1")
pub record HealthRegistry {
  checks: slice[HealthCheck]
}

/// Create an empty registry.
@stable(since="0.1")
pub func create(): HealthRegistry {
  val empty: slice[HealthCheck] = []
  return HealthRegistry(checks = empty)
}

/// Register a liveness check.
///
/// `handlerName` must be the fully-qualified Lyric function name of a function
/// with signature `(): Result[Unit, String]`.
/// Returns Ok(()) when healthy; Err(detail) when unhealthy.
@stable(since="0.1")
pub func addLivenessCheck(
  registry:    in HealthRegistry,
  name:        in String,
  handlerName: in String
): HealthRegistry
  requires: name.length > 0
  requires: handlerName.length > 0
{
  val check = HealthCheck(
    name        = name,
    group       = CheckGroup.Liveness,
    handlerName = handlerName)
  return HealthRegistry(checks = concat(registry.checks, [check]))
}

/// Register a readiness check.
///
/// `handlerName` must be the fully-qualified Lyric function name of a function
/// with signature `(): Result[Unit, String]`.
/// Returns Ok(()) when ready; Err(detail) when not ready.
@stable(since="0.1")
pub func addReadinessCheck(
  registry:    in HealthRegistry,
  name:        in String,
  handlerName: in String
): HealthRegistry
  requires: name.length > 0
  requires: handlerName.length > 0
{
  val check = HealthCheck(
    name        = name,
    group       = CheckGroup.Readiness,
    handlerName = handlerName)
  return HealthRegistry(checks = concat(registry.checks, [check]))
}

// ─── Config ───────────────────────────────────────────────────────────────────

/// URL paths for the two health endpoints.
config Endpoints {
  livePath:  String = "/health/live"
  readyPath: String = "/health/ready"
}

// ─── Route registration ───────────────────────────────────────────────────────

/// The liveness handler name used internally.  The kernel resolves this to the
/// built-in handler that runs liveness checks from the registry.
val livenessHandlerName  = "Health.__handleLiveness"
val readinessHandlerName = "Health.__handleReadiness"

/// Register the liveness and readiness routes on `router` and attach the
/// given registry so the kernel dispatches checks at request time.
///
/// The registered routes are:
///   GET <Endpoints.livePath>   → run all Liveness checks
///   GET <Endpoints.readyPath>  → run all Readiness checks
@stable(since="0.1")
pub func registerRoutes(router: in Router, registry: in HealthRegistry): Router {
  val r1 = addGet(router, "/health/live",  "Health.__handleLiveness")
  val r2 = addGet(r1,     "/health/ready", "Health.__handleReadiness")
  return attachRegistry(r2, registry)
}

// ─── Internal handlers (called by the kernel dispatcher) ─────────────────────

/// Built-in liveness handler.  Runs all `CheckGroup.Liveness` checks and
/// returns the aggregated JSON response.
///
/// WARNING: `pub` visibility is required so the kernel dispatcher can resolve
/// this function by name.  Do not call it directly from application code.
/// Until the kernel dispatcher ships, `runChecks` is a stub that always
/// returns `{"status":"ok"}` regardless of registered checks — see below.
pub func __handleLiveness(): Result[String, ApiError] {
  return runChecks(CheckGroup.Liveness)
}

/// Built-in readiness handler.  Runs all `CheckGroup.Readiness` checks and
/// returns the aggregated JSON response.
///
/// WARNING: same caveats as `__handleLiveness`; stub returns ok unconditionally.
pub func __handleReadiness(): Result[String, ApiError] {
  return runChecks(CheckGroup.Readiness)
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Run all checks for the given group and build a JSON response string.
//
// NOT YET FUNCTIONAL.  The kernel dispatcher (pending milestone) will
// resolve each handlerName via DLL reflection and call the actual check
// functions; until then this function panics rather than silently
// reporting "ok" for an unimplemented liveness/readiness pipeline
// (#367 / #425 item 5 honest framing — a silent stub on a health
// endpoint would let a degraded service ship as healthy).  Real
// dispatcher work is tracked in docs/14.
func runChecks(group: in CheckGroup): Result[String, ApiError] {
  // The match keeps the parameter live so the panic message includes
  // the requested group; today's Lyric panic does not interpolate, so
  // we encode it in the literal string.
  match group {
    case Liveness  -> panic("Health.runChecks(Liveness): kernel dispatcher not yet implemented — see docs/14 and #367.  Do not deploy lyric-health as a production health endpoint until this lands.")
    case Readiness -> panic("Health.runChecks(Readiness): kernel dispatcher not yet implemented — see docs/14 and #367.  Do not deploy lyric-health as a production health endpoint until this lands.")
  }
}

// Attach the registry to the router so the kernel knows which checks to run.
//
// NOT YET FUNCTIONAL: the registry is silently dropped until the router
// supports arbitrary route annotations (tracked as a follow-up milestone).
func attachRegistry(router: in Router, registry: in HealthRegistry): Router {
  // TODO: encode registry into router metadata once the router supports
  //       arbitrary route annotations (tracked as a follow-up milestone).
  //       For now, the registry is stored at module scope and read by the kernel.
  return router
}
