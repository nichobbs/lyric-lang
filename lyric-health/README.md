# lyric-health

Liveness and readiness health-check endpoints for Lyric web services.

## Quick start

```lyric
import Health
import Web
import Db

func checkDb(): Result[Unit, String] {
  val conn = match Db.connectFromEnv() {
    case Ok(c)  -> c
    case Err(e) -> return Err("connect: " + e.message)
  }
  val result = match conn.execute("SELECT 1", []) {
    case Ok(_)  -> Ok(())
    case Err(e) -> Err("db: " + e.message)
  }
  conn.close()
  return result
}

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router, "/users/{id}", "MyService.Handlers.getUser")

  var health = Health.create()
  health = Health.addReadinessCheck(health, "db", "MyService.checkDb")
  router = Health.registerRoutes(router, health)

  Web.start(router)
}
```

This registers two endpoints:

- `GET /health/live` — runs all liveness checks
- `GET /health/ready` — runs all readiness checks

## Implementation status

> **Note:** The kernel dispatcher that resolves check functions by name has not
> yet shipped.  Until it does, registered checks are **never called** — both
> endpoints unconditionally return `{"status":"ok"}`.  Do not rely on these
> endpoints for real health signalling until the dispatcher milestone ships
> (see `docs/14-native-stdlib-plan.md`).

## Check function signature

Check functions must have the signature:

```lyric
func myCheck(): Result[Unit, String]
```

Pass the fully-qualified Lyric function name as a string to `addLivenessCheck`
or `addReadinessCheck`. The kernel resolves it via DLL reflection at request
time, using the same dispatch model as `Web.Route.handlerName`.

## Response format

Responses are JSON:

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

HTTP 200 is returned when status is `"ok"`; HTTP 503 when `"degraded"`.

## Check groups

| Group | Meaning |
|---|---|
| `Liveness` | Process health — a failure should cause the process to be restarted |
| `Readiness` | Traffic readiness — a failure removes the instance from the load balancer |

```lyric
health = Health.addLivenessCheck(health, "memory", "MyService.checkMemory")
health = Health.addReadinessCheck(health, "db", "MyService.checkDb")
health = Health.addReadinessCheck(health, "cache", "MyService.checkCache")
```

## Configuration

Endpoint paths can be overridden via env vars:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_HEALTH_ENDPOINTS_LIVEPATH` | `/health/live` | Liveness endpoint path |
| `LYRIC_CONFIG_HEALTH_ENDPOINTS_READYPATH` | `/health/ready` | Readiness endpoint path |

## API reference

```lyric
Health.create(): HealthRegistry
Health.addLivenessCheck(registry, name, handlerName): HealthRegistry
Health.addReadinessCheck(registry, name, handlerName): HealthRegistry
Health.registerRoutes(router, registry): Web.Router
```

All builder functions are pure and return a new registry; chain them as needed.
`registerRoutes` is the only function that modifies `router`.

## Decision log

See `docs/03-decision-log.md` D057.
