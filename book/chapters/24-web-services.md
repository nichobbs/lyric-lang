# Chapter 24: Web Services

The `lyric-web` library provides a code-first HTTP server that integrates
naturally with Lyric's immutable-value model.  Handlers are referenced by
their fully-qualified function name; the kernel resolves them via DLL
reflection at startup.

## Adding the dependency

```toml
# lyric.toml
[dependencies]
"Lyric.Web" = { path = "../lyric-web" }
```

## Defining a handler

```lyric
import Web

record User { id: String; name: String }

func getUser(id: in String): Result[User, Web.ApiError] {
  if id == "" {
    return Err(Web.badRequest("id is required"))
  }
  // load from DB ...
  return Ok(User(id = id, name = "Alice"))
}
```

Handler functions must return `Result[<T>, Web.ApiError]`.  Path parameters
are extracted from the URL template and passed as `String` arguments in
declaration order.

## Building a router

```lyric
func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router, "/users",         "MyService.Handlers.listUsers")
  router = Web.addGet(router, "/users/{id}",    "MyService.Handlers.getUser")
  router = Web.addPost(router, "/users",        "MyService.Handlers.createUser")
  router = Web.addPut(router, "/users/{id}",    "MyService.Handlers.updateUser")
  router = Web.addDelete(router, "/users/{id}", "MyService.Handlers.deleteUser")
  Web.start(router)
}
```

`Web.start` builds the ASP.NET Core server, registers all routes, and blocks
until the process receives a shutdown signal.

## Path parameters

Parameters enclosed in `{braces}` are extracted as strings and passed to the
handler in declaration order:

```lyric
// Route: /articles/{slug}/comments/{commentId}
func getComment(slug: in String, commentId: in String): Result[Comment, Web.ApiError] {
  // slug and commentId are the extracted path segments
}
```

## Error responses

Use the error helpers to return standard HTTP error codes:

```lyric
return Err(Web.notFound("user not found"))         // 404
return Err(Web.badRequest("invalid email"))        // 400
return Err(Web.unauthorized("token expired"))      // 401
return Err(Web.forbidden("insufficient scope"))    // 403
return Err(Web.conflict("email already taken"))    // 409
return Err(Web.internalError("database error"))    // 500
return Err(Web.serviceUnavailable("db offline"))   // 503
```

## Server configuration

Runtime config (prefix `LYRIC_CONFIG_WEB_SERVER_`):

| Env var | Default | Meaning |
|---|---|---|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8080` | Bind port |
| `READTIMEOUTMS` | `30000` | Request read timeout |
| `WRITETIMEOUTMS` | `30000` | Response write timeout |
| `MAXREQUESTBODYKB` | `4096` | Max request body in KB |
| `SHUTDOWNTIMEOUTMS` | `5000` | Graceful shutdown window |

## Spec-first routing (OpenAPI)

Enable the `openapi` feature in `lyric.toml`:

```toml
[features]
openapi = []
```

Load routes from an OpenAPI 3.x document:

```lyric
import Web
import Web.OpenApi

func main(): Unit {
  var router = Web.create()
  match Web.OpenApi.loadRoutes(router, "MyService.Handlers") {
    case Ok(r)    -> Web.start(r)
    case Err(msg) -> panic("could not load OpenAPI spec: " + msg)
  }
}
```

Each operation in the document must have an `operationId`.  The handler name
is derived as `<handlerModule>.<operationId>`.

## Aspects

The `Web.Aspects` package provides three templates:

### RequestLogging

Logs every matched handler call — elapsed time and ok/err outcome:

```lyric
import Web.Aspects

aspect HttpLog from Web.Aspects.RequestLogging {
  matches: name like "handle*"
}
```

### RateLimiting

Enforces a per-second token-bucket limit per handler.  Returns 429 when exceeded:

```lyric
aspect RateLimit from Web.Aspects.RateLimiting {
  matches: name like "handle*"
  inside:  HttpLog
  config { maxPerSecond: Int = 200 }
}
```

### Timeout

Returns 503 Service Unavailable when elapsed time exceeds the limit:

```lyric
aspect HandlerTimeout from Web.Aspects.Timeout {
  matches: name like "handle*"
  config { timeoutMs: Int = 5000 }
}
```

## Composing with health checks

The `lyric-health` library composes with `Web.Router` through ordinary
named handlers; checks themselves are registered as function references:

```lyric
import Web
import Health

func buildHealth(): HealthRegistry {
  var health = Health.create()
  health = Health.addReadinessCheck(health, "db", { -> checkDb() })
  return health
}

pub func healthReady(): Result[String, ApiError] {
  Health.runReadiness(buildHealth())
}

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router, "/users/{id}", "MyService.Handlers.getUser")
  router = Web.addGet(router, "/health/ready", "MyService.healthReady")

  Web.start(router)
}
```

See Chapter 27 for the full health-check API.
