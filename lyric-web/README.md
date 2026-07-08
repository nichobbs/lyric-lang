# lyric-web

HTTP web service library for [Lyric](https://github.com/nichobbs/lyric-lang). Ships real method/path routing with path parameters, static file serving, a middleware pipeline (CORS built in), OpenAPI 3.1 type vocabulary for spec generation, and aspect templates for authentication and rate limiting.

> **Status**: `@experimental`. Route dispatch, static files, and middleware are implemented and tested (`lyric-web/tests/dispatch_tests.l`) against the `dotnet` target, built on `Std.HttpServer` (`System.Net.HttpListener`). Single-threaded, synchronous accept loop — see [Known gaps](#known-gaps) below.

## Packages

| Package | Description |
|---|---|
| `Web` | Core: `Router`, `Route`, `Request`, `Response`, `Handler`, `Middleware`, `ApiError`, static file serving, the server entry point |
| `Web.OpenApi` | OpenAPI 3.1 spec types (`Spec`, `Schema`, `Operation`, …) and spec builder |
| `Web.Aspects` | Template aspects: `RequiresAuth`, `RequiresRole`, `ApiKey`, `RateLimit`, `HttpCircuitBreaker` |
| `Web.Kernel.Net` | Rate-limiter extern boundary (`ConcurrentDictionary`-backed tumbling window) |

## Installation

```toml
[dependencies]
"Lyric.Web" = { path = "../lyric-web" }
```

---

## Quick start

Route handlers implement the `Handler` interface (`func handle(req): Response`) — an interface rather than a stored closure/function value deliberately: invoking a closure defined in one package from another package that also defines its own closures is unreliable in the current self-hosted MSIL backend, including silent wrong-value corruption with no exception at all (see `docs/03-decision-log.md` D124), the same reason every other pluggable-behavior abstraction in this codebase (`WsHandler`, `MailSender`, `StorageBucket`, …) is an interface rather than a stored closure:

```lyric
package MyService

import Std.Core
import Web

record GetUserHandler {}

impl Web.Handler for GetUserHandler {
  func handle(req: in Web.Request): Web.Response {
    match Web.pathParam(req, "id") {
      case None -> Web.errorResponse(Web.badRequest("missing id"))
      case Some(id) -> match UserRepo.findById(id) {
        case Some(user) -> Web.json(200, userToJson(user))
        case None -> Web.errorResponse(Web.notFound("user " + id + " not found"))
      }
    }
  }
}

record CreateUserHandler {}

impl Web.Handler for CreateUserHandler {
  func handle(req: in Web.Request): Web.Response {
    match parseCreateUserRequest(req.body) {    // hand-rolled Std.Json parsing — see below
      case Err(e) -> Web.errorResponse(e)
      case Ok(input) -> match UserRepo.insert(input) {
        case Ok(user) -> Web.json(201, userToJson(user))
        case Err(e) -> Web.errorResponse(Web.conflict(e.message))
      }
    }
  }
}

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router, "/users/{id}", GetUserHandler())
  router = Web.addPost(router, "/users", CreateUserHandler())
  Web.start(router)
}
```

- **Path parameters**: `{name}` segments are captured into `Request.pathParams`, read with `Web.pathParam(req, "name")`. A trailing `{*name}` segment captures the rest of the path (including `/`) — useful for nested static trees.
- **Query parameters**: `Web.queryParam(req, "name")`.
- **Headers**: `Web.header(req, "name")` — lookup is case-insensitive.
- **Request body**: `req.body: String` (raw text; parse JSON with `Std.Json`, or hand-roll for the request record's shape — see `examples/ledger`, `examples/rbac`, `examples/jobqueue` for worked JSON-parsing examples).
- **Responses**: build with `Web.json`, `Web.text`, `Web.html`, `Web.bytesResponse`, `Web.noContent`, or `Web.errorResponse(apiError)`; add headers with `Web.withResponseHeader`.

There is no automatic request-body deserialization or path/query-parameter-to-function-argument binding — Lyric's project direction has moved away from runtime reflection entirely (see `docs/03-decision-log.md` D099/D006), so this is deliberately explicit rather than "magic". Compose multiple packages' routers with `Web.merge` and scope them with `Web.prefix`.

### Protecting a handler with an aspect

`Web.Aspects` templates (`RequiresAuth`, `RateLimit`, etc.) match against a function's *parameter names* (e.g. `authToken: in String`), not against `Request` objects. Keep your protected business logic in its own plain function with that parameter shape, and call it from your `Handler`'s `handle` body:

```lyric
import Web.Aspects

aspect Auth from Web.Aspects.RequiresAuth {
  matches: name like "guarded*"
  config { jwtSecret: String = "..." }
}

// The aspect wraps this function — authToken is what RequiresAuth reads.
pub func guardedDeleteUser(id: in Long, authToken: in String): Result[String, Web.ApiError] {
  ...
}

// The handler extracts the Authorization header and the path param,
// then maps Result -> Response.
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

router = Web.addDelete(router, "/users/{id}", DeleteUserHandler())
```

See `examples/ledger/src/api.l`, `examples/rbac/src/api.l`, and `examples/jobqueue/src/api.l` for complete worked examples of this pattern (JSON body parsing included).

---

## Static file serving

`Web.StaticFiles` is a library-contributed [config template](../docs/58-wire-templates-sketch.md) (instantiate directly, or in a `wire` graph — see below):

```lyric
router = Web.withStaticFiles(router, Web.StaticFiles(
  root = "./public",
  mountPrefix = "",              // serve at the site root
  cacheControlSeconds = 3600,
  fallbackToIndex = false        // set true for a single-page-app catch-all
))
```

A request that doesn't map to an existing file falls through to the rest of the pipeline (your routes, then a 404) — mount static files before or after your API routes freely. Path traversal is rejected by resolving the candidate path to its canonical absolute form and requiring it to fall within the canonically-resolved root (not a substring check on the raw request path, which an encoding trick could evade).

**Multiple mounts**: call `Web.withStaticFiles` more than once with different `mountPrefix`/`root` pairs:

```lyric
router = Web.withStaticFiles(router, Web.StaticFiles(root = "./public/assets", mountPrefix = "/assets", cacheControlSeconds = 86400, fallbackToIndex = false))
router = Web.withStaticFiles(router, Web.StaticFiles(root = "./data/uploads", mountPrefix = "/uploads", cacheControlSeconds = 0, fallbackToIndex = false))
```

---

## Middleware pipeline

`Web.Middleware` wraps the handler chain — inspect/rewrite the request, short-circuit, or run `next.handle(req)` and inspect/rewrite the response:

```lyric
pub interface Handler {
  func handle(req: in Request): Response
}

pub interface Middleware {
  func wrap(req: in Request, next: Handler): Response
}
```

Register with `Web.withMiddleware(router, mw)` — order is outermost-first (the first middleware registered sees the request first and the response last; the same ordering `contributes[Middleware]` uses in a wire graph, see below). `Web.staticFiles(cfg)` and `Web.corsMiddleware(...)` are both ordinary `Middleware` values, so static file serving composes with your own middleware the same way.

`Web.requestLogger()` logs `METHOD path -> status` for every request; not attached by default:

```lyric
router = Web.withMiddleware(router, Web.requestLogger())
```

### CORS

`Web.start` attaches a CORS middleware automatically from the `LYRIC_CONFIG_WEB_CORS_*` env vars (below) when enabled. Call `Web.corsMiddleware` directly if you build your own pipeline instead of using `Web.start`.

---

## Composing static files + middleware with wire templates

Beyond direct `withStaticFiles`/`withMiddleware` calls, `Web.StaticFiles` (a `pub config` template) and `Web.Middleware` (an ordinary interface) compose with [config templates, `contributes[T]`, and wire templates](../docs/58-wire-templates-sketch.md) (D121) — a library or application can declare a reusable, overridable bundle of static mounts and middleware:

```lyric
pub wire ServerModule {
  @provided appConfig: AppConfig

  config Assets from Web.StaticFiles {
    root: String = "./public"
  }

  contributes[Middleware] cors    = Web.corsMiddleware(appConfig.corsOrigins, "GET,POST", "Content-Type", 600)
  contributes[Middleware] logging = Web.requestLogger()

  singleton router: Web.Router = attachAll(Web.create(), Assets, Middleware)

  expose router
  overridable Assets, cors
}
```

(`attachAll` is an ordinary helper you write: `Web.withMiddleware`-fold over the `contributes[Middleware]`-collected `List[Middleware]`, then `Web.withStaticFiles(router, assets)`.) A consumer includes the module and can override the static root or replace/add middleware without touching the library's declaration:

```lyric
wire ProductionApp {
  @provided appConfig: AppConfig
  include ServerModule {
    Assets { root = "./wwwroot" }
  }
  contributes[Middleware] auth = MyApp.jwtMiddleware(appConfig.jwtSecret)
    inside: logging
  expose router
}
```

See `docs/58-wire-templates-sketch.md` and D121 (`docs/03-decision-log.md`) for the full config-template / `contributes[T]` / wire-template design and diagnostics.

---

## Runtime configuration

All config fields are env-var-backed, read once at startup, fail-fast if a required field is missing.

### Server

| Env var | Type | Default | Description |
|---|---|---|---|
| `LYRIC_CONFIG_WEB_SERVER_HOST` | `String` | `0.0.0.0` | Bind address |
| `LYRIC_CONFIG_WEB_SERVER_PORT` | `Int` | `8080` | TCP port (1–65535) |

### CORS

| Env var | Type | Default | Description |
|---|---|---|---|
| `LYRIC_CONFIG_WEB_CORS_ENABLED` | `Bool` | `false` | Enable CORS middleware |
| `LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS` | `String` | `*` | Comma-separated origins (or `*`) |
| `LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS` | `String` | `GET,POST,PUT,DELETE,OPTIONS,PATCH` | Comma-separated methods |
| `LYRIC_CONFIG_WEB_CORS_ALLOWEDHEADERS` | `String` | `Content-Type,Authorization,Accept` | Comma-separated headers |
| `LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS` | `Int` | `86400` | Preflight cache duration |

---

## Aspect templates

### `Web.Aspects.RequiresAuth`

Validates a Bearer JWT on every matched handler. **Row-constrained B'-mode** (docs/56): reads `args.authToken` via a `where TArgs has { authToken: String }` row clause — apply only to (business-logic) functions that declare an `authToken: String` parameter, per [Protecting a handler with an aspect](#protecting-a-handler-with-an-aspect) above.

```lyric
import Web.Aspects

aspect Auth from Web.Aspects.RequiresAuth {
  matches: name like "guarded*"
  except name in { guardedHealth, guardedOpenApiSpec }
}
```

| Config field | Type | Default | Env var (`Auth` instantiation) |
|---|---|---|---|
| `enabled` | `Bool` | `true` | `LYRIC_ASPECT_AUTH_ENABLED` |
| `jwtSecret` | `String` | **REQUIRED** | `LYRIC_ASPECT_AUTH_JWTSECRET` |
| `issuer` | `String` | `""` | `LYRIC_ASPECT_AUTH_ISSUER` |
| `audience` | `String` | `""` | `LYRIC_ASPECT_AUTH_AUDIENCE` |

The `jwtSecret` field is `@sensitive` — its value is redacted in `lyric explain` and Swagger UI metadata output.

### `Web.Aspects.RateLimit`

Enforces a per-endpoint sliding-window rate limit. **B-mode**: uses `call.qualifiedName` as the bucket key.

```lyric
aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "guarded*"
  inside:  Auth       // run inside Auth's envelope
  config {
    requestsPerMinute: Int = 30
    burstSize:         Int = 5
  }
}
```

| Config field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `requestsPerMinute` | `Int` | `60` | Max calls per 60-second window |
| `burstSize` | `Int` | `10` | Max calls per second |

`Web.Aspects.RequiresRole`, `Web.Aspects.ApiKey`, and `Web.Aspects.HttpCircuitBreaker` follow the same template shape — see `lyric-web/src/aspects.l` and `lyric-web/tests/security_aspect_weaving_tests.l`.

---

## OpenAPI: code-first and spec-first

`Web.OpenApi` is a hand-built spec vocabulary — populate a `Spec` value in your package and pass it to `lyric web spec` to emit `openapi.yaml`, or run `lyric generate openapi spec.yaml --out src/generated/` to scaffold record types + handler stubs from an existing spec. See the module doc comment in `lyric-web/src/openapi.l` for the full type mapping and constraint-to-`requires:` table. (`Web.Route`/`Router` don't carry a `Spec` at runtime — see [Known gaps](#known-gaps) for live spec serving.)

---

## ApiError constructors

| Function | Status | Description |
|---|---|---|
| `badRequest(msg)` | 400 | Malformed input or validation failure |
| `badRequestWithDetail(msg, [fields])` | 400 | With per-field validation messages |
| `unauthorized(msg)` | 401 | Missing or invalid credentials |
| `forbidden(msg)` | 403 | Caller lacks permission |
| `notFound(msg)` | 404 | Resource does not exist |
| `conflict(msg)` | 409 | State collision |
| `unprocessable(msg, [detail])` | 422 | Valid request, domain rule violation |
| `tooManyRequests(msg)` | 429 | Rate limit exceeded |
| `internalError(msg)` | 500 | Unexpected server error |
| `serviceUnavailable(msg)` | 503 | Upstream dependency unreachable or degraded |
| `apiError(status, msg)` | any | Custom status code (100–599) |

Convert to a `Response` with `Web.errorResponse(err)`.

---

## Known gaps

- **Single-threaded accept loop.** `Web.serve` handles one request at a time — fine for the examples and moderate traffic, not a high-concurrency production server. Concurrent request handling needs either real MSIL structured concurrency (`spawn` currently lowers to a synchronous no-op on `--target dotnet`) or a hand-rolled thread pool; not yet implemented.
- **`Web.addWorker` background timers are registered but not invoked** — tracked in issue #5359.
- **Live OpenAPI JSON / Swagger UI serving is not implemented** — tracked in issue #5360. Use the build-time `lyric web spec` workflow instead.
- **JVM target**: `lyric-web` only supports `dotnet` today (`Std.HttpServer`'s JVM kernel doesn't yet expose the query-string/header/byte-body primitives this library needs — see `lyric-stdlib/std/_kernel_jvm/http_server.l`'s header comment). Phase 6.

## Package layout

```
lyric-web/
  lyric.toml                      package manifest
  README.md                       this file
  src/
    web.l                         Web  (Router, Request, Response, Middleware, static files, start)
    openapi.l                     Web.OpenApi  (spec types + builder)
    aspects.l                     Web.Aspects  (RequiresAuth, RequiresRole, ApiKey, RateLimit, HttpCircuitBreaker)
    _kernel/
      net/web_kernel.l            Web.Kernel.Net  (rate-limiter extern boundary)
  tests/
    dispatch_tests.l              Web.dispatch: routing, path/query/headers, static files, middleware, CORS
    cors_guard_tests.l            CORS startup-guard validation
    rate_limit_tests.l            Web.Kernel.Net.checkRateLimit
    security_aspect_weaving_tests.l  Web.Aspects templates, woven
```

## See also

- `docs/26-aspects.md` §18 — aspect template instantiation rules
- `docs/27-aspect-libraries.md` — cross-package aspect distribution
- `docs/58-wire-templates-sketch.md` — config templates / `contributes[T]` / wire templates
- `docs/25-config-blocks.md` — config block semantics (D046)
- `docs/03-decision-log.md` D053 (original design), D099 (function-reference dispatch precedent), D121 (wire templates), D124 (this library's dispatch fix + static files + middleware)
