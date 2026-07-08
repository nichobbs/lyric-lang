# Chapter 24: Web Services

The `lyric-web` library provides an HTTP server with real method/path
routing, path parameters, static file serving, a middleware pipeline
(CORS included), and OpenAPI 3.1 type vocabulary for spec generation.
It is `@experimental` and `dotnet`-only today; see
`lyric-web/README.md`'s "Known gaps" section for the current limits.

## Adding the dependency

```toml
# lyric.toml
[dependencies]
"Lyric.Web" = { path = "../lyric-web" }
```

## Defining a handler

Route handlers implement the `Web.Handler` interface
(`func handle(req): Response`) — an interface rather than a stored
closure/function value deliberately: invoking a closure defined in one
package from another package that also defines its own closures is
unreliable in the current self-hosted MSIL backend (see
`docs/03-decision-log.md` D124), the same reason every other
pluggable-behavior abstraction in this codebase (`WsHandler`,
`MailSender`, `StorageBucket`, …) is an interface rather than a stored
closure.

```lyric
import Web

record User { id: String; name: String }

record GetUserHandler {}

impl Web.Handler for GetUserHandler {
  func handle(req: in Web.Request): Web.Response {
    match Web.pathParam(req, "id") {
      case None -> Web.errorResponse(Web.badRequest("id is required"))
      case Some(id) -> Web.json(200, userToJson(User(id = id, name = "Alice")))
    }
  }
}
```

There is no automatic request-body deserialization or
path/query-parameter-to-handler-argument binding — Lyric's project
direction has moved away from runtime reflection entirely (D006/D099),
so a handler reads what it needs explicitly:

- **Path parameters**: `Web.pathParam(req, "name")` — `{name}` segments
  are captured into `Request.pathParams`. A trailing `{*name}` segment
  captures the rest of the path (including `/`).
- **Query parameters**: `Web.queryParam(req, "name")`.
- **Headers**: `Web.header(req, "name")` — case-insensitive.
- **Request body**: `req.body: String` (raw text — parse JSON with
  `Std.Json`, or hand-roll a parser for the request shape; see
  `examples/ledger/src/api.l` for a worked example).

## Building a router

```lyric
func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router, "/users", ListUsersHandler())
  router = Web.addGet(router, "/users/{id}", GetUserHandler())
  router = Web.addPost(router, "/users", CreateUserHandler())
  router = Web.addPut(router, "/users/{id}", UpdateUserHandler())
  router = Web.addDelete(router, "/users/{id}", DeleteUserHandler())
  Web.start(router)
}
```

`Web.start` reads `LYRIC_CONFIG_WEB_SERVER_*`/`LYRIC_CONFIG_WEB_CORS_*`
from the environment, starts the HTTP listener (built on
`Std.HttpServer`, i.e. `System.Net.HttpListener`), and blocks until the
process is killed. It is single-threaded and synchronous — one request
at a time — which is a known limit, not a design goal; see the README's
"Known gaps".

Compose multiple packages' routers with `Web.merge` and scope them
with `Web.prefix`.

## Static file serving

```lyric
router = Web.withStaticFiles(router, Web.StaticFiles(
  root = "./public",
  mountPrefix = "",              // serve at the site root
  cacheControlSeconds = 3600,
  fallbackToIndex = false        // set true for a single-page-app catch-all
))
```

A request that doesn't map to an existing file falls through to the
rest of the pipeline (your routes, then a 404). Path traversal is
rejected by resolving the candidate path to its canonical absolute form
and requiring it fall within the canonically resolved root. Mount
several roots at different prefixes by calling `withStaticFiles` more
than once.

## Middleware

```lyric
pub interface Middleware {
  func wrap(req: in Request, next: Handler): Response
}
```

Register with `Web.withMiddleware(router, mw)` — outermost-first order
(the first middleware registered sees the request first and the
response last). `Web.corsMiddleware(...)` and `Web.staticFiles(cfg)`
are both ordinary `Middleware` values. `Web.requestLogger()` logs
`METHOD path -> status` for every request (not attached by default).
`Web.start` attaches a CORS middleware automatically from
`LYRIC_CONFIG_WEB_CORS_*` when enabled.

See `docs/58-wire-templates-sketch.md` for composing static mounts and
middleware via `contributes[Middleware]` in a `wire` graph.

## Error responses

Build a `Response` from an `ApiError` with `Web.errorResponse`:

```lyric
Web.errorResponse(Web.notFound("user not found"))         // 404
Web.errorResponse(Web.badRequest("invalid email"))        // 400
Web.errorResponse(Web.unauthorized("token expired"))      // 401
Web.errorResponse(Web.forbidden("insufficient scope"))    // 403
Web.errorResponse(Web.conflict("email already taken"))    // 409
Web.errorResponse(Web.internalError("database error"))    // 500
Web.errorResponse(Web.serviceUnavailable("db offline"))   // 503
```

## Server configuration

Runtime config (all read once at startup, fail-fast if invalid):

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_CONFIG_WEB_SERVER_HOST` | `0.0.0.0` | Bind address |
| `LYRIC_CONFIG_WEB_SERVER_PORT` | `8080` | Bind port (1–65535) |
| `LYRIC_CONFIG_WEB_CORS_ENABLED` | `false` | Enable CORS middleware |
| `LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS` | `*` | Comma-separated origins (required when enabled) |
| `LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS` | `GET,POST,PUT,DELETE,OPTIONS,PATCH` | Comma-separated methods |
| `LYRIC_CONFIG_WEB_CORS_ALLOWEDHEADERS` | `Content-Type,Authorization,Accept` | Comma-separated headers |
| `LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS` | `86400` | Preflight cache duration |

## OpenAPI: code-first and spec-first

`Web.OpenApi` is a hand-built spec vocabulary, decoupled from `Router` at
runtime — populate a `Spec` value in your package and run
`lyric web spec` to emit `openapi.yaml`, or run
`lyric generate openapi spec.yaml --out src/generated/` to scaffold
record types and handler stubs from an existing spec. See
`lyric-web/src/openapi.l`'s module doc comment for the full
schema-to-Lyric-type mapping and the constraint-to-`requires:` table.
Live OpenAPI JSON / Swagger UI serving is not implemented yet (tracked
in issue #5360); `Router` doesn't carry a `Spec` at runtime.

## Aspects

`Web.Aspects` ships five templates: `RequiresAuth`, `RequiresRole`,
`ApiKey`, `RateLimit`, and `HttpCircuitBreaker`. They match against a
function's *parameter names* (e.g. `authToken: in String`), not against
`Request` objects, so keep protected business logic in its own plain
function and call it from your `Handler`'s `handle` body:

```lyric
import Web.Aspects

aspect Auth from Web.Aspects.RequiresAuth {
  matches: name like "guarded*"
  config { jwtSecret: String = "..." }
}

// The aspect wraps this function — authToken is what RequiresAuth reads.
pub func guardedDeleteUser(id: in Long, authToken: in String): Result[String, Web.ApiError] {
  // ...
}

record DeleteUserHandler {}
impl Web.Handler for DeleteUserHandler {
  func handle(req: in Web.Request): Web.Response {
    val token = match Web.header(req, "authorization") {
      case Some(v) -> if v.startsWith("Bearer ") { v.substring(7) } else { v }
      case None -> ""
    }
    match Web.pathParam(req, "id") {
      case None -> Web.errorResponse(Web.badRequest("missing id"))
      case Some(raw) -> match parseOptLong(raw) {
        case None -> Web.errorResponse(Web.badRequest("id must be an integer"))
        case Some(id) -> match guardedDeleteUser(id, token) {
          case Ok(body) -> Web.json(200, body)
          case Err(e) -> Web.errorResponse(e)
        }
      }
    }
  }
}

aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "guarded*"
  inside:  Auth
  config { requestsPerMinute: Int = 200 }
}
```

See `lyric-web/README.md`'s "Aspect templates" section for the full
config-field tables, and `examples/ledger/src/api.l` /
`examples/rbac/src/api.l` / `examples/jobqueue/src/api.l` for complete
worked examples.

## Composing with health checks

The `lyric-health` library composes with `Web.Router` through ordinary
`Handler` implementations; checks themselves are registered as function
references:

```lyric
import Web
import Health

func checkDb(): CheckStatus {
  // ...
}

func buildHealth(): HealthRegistry {
  var health = Health.create()
  health = Health.addReadinessCheck(health, "db", { -> checkDb() })
  return health
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
  router = Web.addGet(router, "/health/ready", HealthReadyHandler())

  Web.start(router)
}
```

See Chapter 27 for the full health-check API.
