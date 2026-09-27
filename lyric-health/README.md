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

## Fault isolation and timeouts

Every check runs through `Health.runCheckIsolated` (internal), which:

- **Catches a panic.** If a check's handler panics, `runChecks` reports
  that check as unhealthy with the generic detail `"check panicked"` —
  the panic's own message is never included in the HTTP response body
  (it would otherwise leak internal error text to callers of
  `/health/live` / `/health/ready`). A panicking check never turns the
  whole endpoint into an unhandled 500, and it never stops the remaining
  checks in the group from running.
- **Bounds execution time**, on `--target dotnet` only. Each `HealthCheck`
  carries a `timeoutMs` budget (`defaultCheckTimeoutMs` = 5000 unless
  overridden via `addLivenessCheckWithTimeout` /
  `addReadinessCheckWithTimeout`). On `--target dotnet`, the handler runs
  on a background thread (`Health.Kernel.Net`, a real BCL
  `Task.Run`/`Task.Wait(int)` bound) and the calling thread returns after
  at most `timeoutMs`, reporting the check unhealthy with a
  `"timed out after <timeoutMs>ms"` detail if the handler hasn't finished
  by then.

  **On `--target jvm`, `timeoutMs` is validated but not enforced.** There
  is currently no existing Lyric facility to preemptively bound an
  arbitrary check closure's execution time on the JVM backend: a Lyric
  closure has no bridge to any JDK functional interface
  (`Runnable`/`Callable`) outside the compiler's own `spawn`/`scope { }`
  keyword codegen (see `lyric-stdlib/std/_kernel_jvm/task.l`'s module
  header, which documents this after empirically verifying it), and even
  that keyword codegen's `scope { }` join and `await` have no
  bounded/timeout variant to race against. A hanging check therefore
  still hangs `runLiveness`/`runReadiness` on `--target jvm`; only panic
  isolation is real there. Query `Health.timeoutEnforced` (`true` on
  `--target dotnet`, `false` on `--target jvm`) if a caller needs to know
  which guarantee applies. Bringing JVM to parity needs a genuine
  Callable/Future auto-FFI bridge for arbitrary Lyric closures — tracked in #7461,
  as a follow-up, not silently faked here.

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
Health.addLivenessCheckWithTimeout(registry, name, handler, timeoutMs): HealthRegistry
Health.addReadinessCheck(registry, name, handler): HealthRegistry
Health.addReadinessCheckWithTimeout(registry, name, handler, timeoutMs): HealthRegistry
Health.hasCheckNamed(registry, name): Bool
Health.pass(): CheckStatus
Health.fail(detail): CheckStatus
Health.runChecks(registry, group): HealthReport
Health.runLiveness(registry): Result[String, String]
Health.runReadiness(registry): Result[String, String]
Health.isLiveness(group): Bool
Health.isReadiness(group): Bool
Health.defaultCheckTimeoutMs: Int
Health.timeoutEnforced: Bool
```

All builder functions are pure and return a new registry; chain them as
needed.  `runChecks` invokes each registered handler in the requested
group exactly once, in registration order, isolated per "Fault isolation
and timeouts" above.

`addLivenessCheck`/`addReadinessCheck` (and their `*WithTimeout` variants)
require a non-empty `name` and reject registering a name that already
exists anywhere in the registry (`Health.hasCheckNamed`) — two checks
sharing a name would collide into one JSON key in the response body. The
`*WithTimeout` variants additionally require `timeoutMs >= 1`.

## Decision log

See `docs/03-decision-log.md` D057 (original design) and D099
(function-reference registration, superseding the name-based
DLL-reflection dispatcher plan).
