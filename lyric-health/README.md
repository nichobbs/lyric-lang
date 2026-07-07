# lyric-health

Liveness and readiness health checks for Lyric web services.

Checks are registered as **function references** (closures) and invoked
directly by `Health.runChecks` — the same AOT-safe model as
`Lambda.Direct` (see `docs/35-lambda-library.md` §10).  No runtime
reflection or name-based dispatch is involved.

## Quick start

```lyric
import Health
import Web
import Db

func checkDb(): CheckStatus {
  val conn = match Db.connectFromEnv() {
    case Ok(c)  -> c
    case Err(e) -> return Health.fail("connect: " + e.message)
  }
  val status = match conn.execute("SELECT 1", []) {
    case Ok(_)  -> Health.pass()
    case Err(e) -> Health.fail("db: " + e.message)
  }
  conn.close()
  return status
}

func buildHealth(): HealthRegistry {
  var health = Health.create()
  health = Health.addLivenessCheck(health, "self", { -> Health.pass() })
  health = Health.addReadinessCheck(health, "db", { -> checkDb() })
  return health
}

// Web.Route handlers are (Web.Request) -> Web.Response; wrap
// runLiveness/runReadiness's Result[String, String] in a thin adapter
// and register the adapter directly (a function reference, no
// name-based dispatch):
pub func healthLive(req: in Web.Request): Web.Response {
  match Health.runLiveness(buildHealth()) {
    case Ok(body) -> Web.json(200, body)
    case Err(msg) -> Web.errorResponse(Web.serviceUnavailable(msg))
  }
}

pub func healthReady(req: in Web.Request): Web.Response {
  match Health.runReadiness(buildHealth()) {
    case Ok(body) -> Web.json(200, body)
    case Err(msg) -> Web.errorResponse(Web.serviceUnavailable(msg))
  }
}

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router, "/health/live", healthLive)
  router = Web.addGet(router, "/health/ready", healthReady)
  Web.start(router)
}
```

- `GET /health/live` — runs all liveness checks
- `GET /health/ready` — runs all readiness checks

## Check function signature

Check handlers have the signature:

```lyric
() -> CheckStatus
```

Return `Health.pass()` when the check succeeds and
`Health.fail("human-readable reason")` when it does not.  Register the
handler as a closure: `Health.addReadinessCheck(health, "db", { -> checkDb() })`.
The closure is stored in the registry and invoked directly when checks
run — the compiler roots it at the registration site, so the model is
compatible with Native AOT trimming.

## Response format

`runChecks` produces a `HealthReport` whose `body` is JSON:

```json
{
  "status": "ok",
  "checks": {
    "db": { "status": "ok", "detail": "" }
  }
}
```

When any check fails:

```json
{
  "status": "degraded",
  "checks": {
    "db": { "status": "fail", "detail": "connection refused" }
  }
}
```

`runLiveness` / `runReadiness` return `Ok(body)` (the JSON above) when
every check passes, or `Err(message)` naming the failing checks when
degraded — map the `Err` case to `Web.serviceUnavailable(message)` (503)
in your route adapter, as the Quick start example above does.

## Check groups

| Group | Meaning |
|---|---|
| `Liveness` | Process health — a failure should cause the process to be restarted |
| `Readiness` | Traffic readiness — a failure removes the instance from the load balancer |

```lyric
health = Health.addLivenessCheck(health, "memory", { -> checkMemory() })
health = Health.addReadinessCheck(health, "db", { -> checkDb() })
health = Health.addReadinessCheck(health, "cache", { -> checkCache() })
```

To inspect a stored check's group, use `Health.isLiveness(check.group)` /
`Health.isReadiness(check.group)` rather than matching `CheckGroup` from a
consuming package (cross-package union case dispatch is not yet reliable
in the self-hosted backend; the helpers match inside the defining
assembly where dispatch is exact).

## API reference

```lyric
Health.create(): HealthRegistry
Health.addLivenessCheck(registry, name, handler): HealthRegistry
Health.addReadinessCheck(registry, name, handler): HealthRegistry
Health.pass(): CheckStatus
Health.fail(detail): CheckStatus
Health.runChecks(registry, group): HealthReport
Health.runLiveness(registry): Result[String, String]
Health.runReadiness(registry): Result[String, String]
Health.isLiveness(group): Bool
Health.isReadiness(group): Bool
```

All builder functions are pure and return a new registry; chain them as
needed.  `runChecks` invokes each registered handler in the requested
group exactly once, in registration order.

## Decision log

See `docs/03-decision-log.md` D057 (original design) and D099
(function-reference registration, superseding the name-based
DLL-reflection dispatcher plan).
