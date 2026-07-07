# Chapter 27: Health Checks

The `lyric-health` library runs liveness and readiness health checks for a
web service.  Orchestrators such as Kubernetes probe health endpoints to
decide whether to restart a pod or remove it from the load balancer.

Checks are registered as **function references** (closures) and invoked
directly when checks run — the same AOT-safe registration model as
`Lambda.Direct` (Chapter 28 / `docs/35-lambda-library.md` §10).  No
runtime reflection or name-based dispatch is involved.

## Adding the dependency

```toml
# lyric.toml
[dependencies]
"Lyric.Web"    = { path = "../lyric-web" }
"Lyric.Health" = { path = "../lyric-health" }
```

## Quick start

```lyric
import Web
import Health

func checkDb(): CheckStatus {
  // returns Health.pass() when healthy, Health.fail("reason") when not
  Health.pass()
}

func buildHealth(): HealthRegistry {
  var health = Health.create()
  health = Health.addLivenessCheck(health, "self", { -> Health.pass() })
  health = Health.addReadinessCheck(health, "db", { -> checkDb() })
  return health
}

// Web.Route handlers implement Web.Handler; wrap runLiveness/runReadiness's
// Result[String, String] in a thin handler (a function reference, no
// name-based dispatch):
record HealthLiveHandler {}
impl Web.Handler for HealthLiveHandler {
  func handle(req: in Web.Request): Web.Response {
    match Health.runLiveness(buildHealth()) {
      case Ok(body) -> Web.json(200, body)
      case Err(msg) -> Web.errorResponse(Web.serviceUnavailable(msg))
    }
  }
}

record HealthReadyHandler {}
impl Web.Handler for HealthReadyHandler {
  func handle(req: in Web.Request): Web.Response {
    match Health.runReadiness(buildHealth()) {
      case Ok(body) -> Web.json(200, body)
      case Err(msg) -> Web.errorResponse(Web.serviceUnavailable(msg))
    }
  }
}

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router, "/users/{id}", GetUserHandler())
  router = Web.addGet(router, "/health/live", HealthLiveHandler())
  router = Web.addGet(router, "/health/ready", HealthReadyHandler())

  Web.start(router)
}
```

This serves:

- `GET /health/live` — runs all liveness checks
- `GET /health/ready` — runs all readiness checks

## Check function signature

```lyric
() -> CheckStatus
```

- Return `Health.pass()` when the check succeeds.
- Return `Health.fail("human-readable reason")` when it fails.
- Register the handler as a closure:
  `Health.addReadinessCheck(health, "db", { -> checkDb() })`.
- The closure is stored in the registry and invoked directly by
  `runChecks` — the compiler roots it at the registration site, so the
  model is compatible with Native AOT trimming.

## Liveness vs readiness

| Group | Register with | Meaning |
|---|---|---|
| `Liveness` | `addLivenessCheck` | Process is alive; failure triggers a restart |
| `Readiness` | `addReadinessCheck` | Process is ready for traffic; failure removes it from the LB |

Use liveness for conditions that indicate a stuck or corrupt process (memory
exhaustion, deadlock).  Use readiness for conditions that indicate temporary
unavailability (database not yet connected, warm-up in progress).

```lyric
health = Health.addLivenessCheck(health,  "leak-detector", { -> checkLeaks() })
health = Health.addReadinessCheck(health, "db",            { -> checkDb() })
health = Health.addReadinessCheck(health, "cache",         { -> checkCache() })
```

## Running checks

`runChecks(registry, group)` invokes every handler registered for the
group exactly once, in registration order, and returns a `HealthReport`:

```lyric
val report = Health.runChecks(registry, Readiness)
report.healthy   // Bool — true only when every check in the group passed
report.body      // String — the JSON response body below
```

`runLiveness(registry)` / `runReadiness(registry)` return
`Result[String, String]`: `Ok(body)` when healthy, `Err(message)`
naming the failing checks when degraded — map the `Err` case to
`Web.serviceUnavailable(message)` (503) in your route handler, as the
Quick start example above does.

## Response format

### All checks pass

```json
{
  "status": "ok",
  "checks": {
    "db":    { "status": "ok",   "detail": "" },
    "cache": { "status": "ok",   "detail": "" }
  }
}
```

HTTP status: `200 OK`

### One or more checks fail

```json
{
  "status": "degraded",
  "checks": {
    "db":    { "status": "fail", "detail": "connection refused" },
    "cache": { "status": "ok",   "detail": "" }
  }
}
```

HTTP status: `503 Service Unavailable`

## API summary

```lyric
Health.create(): HealthRegistry
Health.addLivenessCheck(registry, name, handler): HealthRegistry
Health.addReadinessCheck(registry, name, handler): HealthRegistry
Health.pass(): CheckStatus
Health.fail(detail): CheckStatus
Health.runChecks(registry, group): HealthReport
Health.runLiveness(registry): Result[String, ApiError]
Health.runReadiness(registry): Result[String, ApiError]
Health.isLiveness(group): Bool
Health.isReadiness(group): Bool
```

All builder functions are pure: they return a new `HealthRegistry` without
modifying the original.  To inspect a stored check's group, prefer
`isLiveness` / `isReadiness` over matching `CheckGroup` from a consuming
package (cross-package union case dispatch is not yet reliable in the
self-hosted backend; the helpers match inside the defining assembly).

## Database health check example

```lyric
import Db

func checkDb(): CheckStatus {
  val conn = match Db.connectFromEnv() {
    case Ok(c)  -> c
    case Err(e) -> return Health.fail("connect: " + e.message)
  }
  val status = match conn.execute("SELECT 1", []) {
    case Ok(_)  -> Health.pass()
    case Err(e) -> Health.fail("ping: " + e.message)
  }
  conn.close()
  return status
}
```

Register it:

```lyric
health = Health.addReadinessCheck(health, "db", { -> checkDb() })
```
