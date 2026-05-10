# Chapter 27: Health Checks

The `lyric-health` library adds liveness and readiness health-check endpoints
to a `Web.Router`.  Orchestrators such as Kubernetes probe these endpoints to
decide whether to restart a pod or remove it from the load balancer.

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

func checkDb(): Result[Unit, String] {
  // returns Ok(()) when healthy, Err("reason") when not
  Ok(())
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

This registers:

- `GET /health/live` — runs all liveness checks
- `GET /health/ready` — runs all readiness checks

## Check function signature

```lyric
func myCheck(): Result[Unit, String]
```

- Return `Ok(())` when the check passes.
- Return `Err("human-readable reason")` when it fails.
- The function is referenced by its fully-qualified Lyric name.
- The kernel resolves it via DLL reflection at request time.

## Liveness vs readiness

| Group | Register with | Meaning |
|---|---|---|
| `Liveness` | `addLivenessCheck` | Process is alive; failure triggers a restart |
| `Readiness` | `addReadinessCheck` | Process is ready for traffic; failure removes it from the LB |

Use liveness for conditions that indicate a stuck or corrupt process (memory
exhaustion, deadlock).  Use readiness for conditions that indicate temporary
unavailability (database not yet connected, warm-up in progress).

```lyric
health = Health.addLivenessCheck(health,  "goroutine-leak", "MyService.checkLeaks")
health = Health.addReadinessCheck(health, "db",             "MyService.checkDb")
health = Health.addReadinessCheck(health, "cache",          "MyService.checkCache")
```

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

## Configuration

Endpoint paths (env prefix `LYRIC_CONFIG_HEALTH_ENDPOINTS_`):

| Env var | Default | Meaning |
|---|---|---|
| `LIVEPATH` | `/health/live` | Liveness endpoint path |
| `READYPATH` | `/health/ready` | Readiness endpoint path |

Override these when the defaults conflict with another route in your service.

## Implementation status

> **Note:** The kernel dispatcher that resolves check functions by name and
> executes them at request time has not yet shipped.  Until it does,
> `Health.registerRoutes` installs the endpoints but **checks are never
> called** — both `/health/live` and `/health/ready` unconditionally return
> `{"status":"ok"}` regardless of what checks are registered.  Do not rely
> on these endpoints for real health signalling until the dispatcher milestone
> is complete (see `docs/14-native-stdlib-plan.md`).

## API summary

```lyric
Health.create(): HealthRegistry
Health.addLivenessCheck(registry, name, handlerName): HealthRegistry
Health.addReadinessCheck(registry, name, handlerName): HealthRegistry
Health.registerRoutes(router, registry): Web.Router
```

All builder functions are pure: they return a new `HealthRegistry` without
modifying the original.  `registerRoutes` is the only function that touches
the `Web.Router`.

## Database health check example

```lyric
import Db

func checkDb(): Result[Unit, String] {
  val conn = match Db.connectPostgres() {
    case Ok(c)  -> c
    case Err(e) -> return Err("connect: " + e.message)
  }
  val result = match conn.execute("SELECT 1", []) {
    case Ok(_)  -> Ok(())
    case Err(e) -> Err("ping: " + e.message)
  }
  conn.close()
  return result
}
```

Register it:

```lyric
health = Health.addReadinessCheck(health, "db", "MyService.checkDb")
```
