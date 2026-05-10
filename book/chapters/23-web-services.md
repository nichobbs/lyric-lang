# Web Services

Most backend services spend their lives doing three things: accepting an HTTP request, running some business logic, and returning a response. Lyric's `lyric-web` library is designed to make that cycle as safe as the rest of the language: handlers are ordinary Lyric functions with ordinary contracts, errors are typed values rather than thrown exceptions, and runtime configuration flows through the same `config { }` blocks you use elsewhere in your service.

This chapter covers the two workflows the library supports: code-first (write handlers, build a router, start the server) and spec-first (generate handlers and types from an OpenAPI document). It also covers the three companion packages that handle authentication, rate limiting, and OpenAPI documentation, and finishes with a complete example that wires everything together.

::: note
**Bootstrap status.** The `lyric-web` packages can be imported and routers can be built and type-checked today. HTTP serving (the Kestrel backend in `Web.Kernel.Net`) and aspect weaving (`Web.Aspects`) are not yet shipped as of v1. The API described here represents the intended surface; import it, write handlers, and compose routers now; serving and aspect weaving take effect once those milestones ship.
:::

## §23.1 Installation and packages

Add `lyric-web` to your manifest. The Kestrel backend is behind a feature flag because it pulls in a .NET host-platform dependency that you may not want in every build:

```toml
[package]
name    = "MyService"
version = "1.0.0"

[dependencies]
"Lyric.Web" = { path = "../lyric-web" }

[features]
dotnet = []    # enable the Kestrel backend
```

Build with `--features dotnet` to activate the server:

```sh
lyric build --manifest lyric.toml --features dotnet
```

The library is split into four packages with distinct responsibilities:

| Package | What it provides |
|---|---|
| `Web` | Routing, `ApiError`, `config Server`, `config Cors`, `Web.start()` |
| `Web.OpenApi` | OpenAPI 3.1 type vocabulary and builder |
| `Web.Aspects` | `RequiresAuth` and `RateLimit` aspect templates |
| `Web.Kernel.Net` | `@cfg(feature = "dotnet")` extern boundary to Kestrel |

You only need to import `Web` for basic routing. The other three packages are opt-in.

## §23.2 Code-first: handlers, routers, and startup

The code-first workflow has three steps: write handler functions, register them in a router, and call `Web.start()`.

### §23.2.1 Writing handlers

A handler is a regular Lyric function annotated with an HTTP method and path. The annotations live in the `Web` package and are applied the same way as any other Lyric annotation:

```lyric
package MyService.Handlers

import Std.Core
import Web

@get("/users/{id}")
@tag("users")
pub func getUser(id: in Int): Result[User, ApiError]
  requires: id > 0
{
  match UserRepo.findById(id) {
    case Some(user) -> Ok(user)
    case None       -> Err(Web.notFound("user " + id.toString() + " not found"))
  }
}

@post("/users")
@tag("users")
pub func createUser(@body req: in CreateUserRequest): Result[User, ApiError]
  requires: req.name.length > 0
{
  match UserRepo.insert(req) {
    case Ok(user) -> Ok(user)
    case Err(e)   -> Err(Web.conflict(e.message))
  }
}
```

A few things to notice.

Path parameters (`{id}`) bind to function parameters by name. The compiler checks that every path parameter has a matching function parameter with a compatible type. If you rename `id` to `userId` in the function signature but leave `{id}` in the path, the compiler reports the mismatch.

The `@body` annotation marks a parameter as the deserialized request body. Only one parameter per handler may carry `@body`. The type must be a `pub record` so the compiler can generate the JSON deserializer.

The return type is `Result[T, ApiError]`. The `Ok` branch serializes `T` as the JSON response body; the `Err` branch serializes `ApiError` and uses its embedded HTTP status code. You never write serialization code by hand.

`requires:` clauses on a handler are checked at the boundary: the runtime evaluates the precondition against the incoming data and returns a 400 response with the contract violation message if it fails. This means a `requires: id > 0` on a handler is an input validation rule, not just a proof obligation.

### §23.2.2 Building a router

Once you have handlers, construct a router and register them:

```lyric
package MyService

import Std.Core
import Web
import MyService.Handlers

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router,  "/users/{id}", "MyService.Handlers.getUser")
  router = Web.addPost(router, "/users",      "MyService.Handlers.createUser")
  Web.start(router)
}
```

`Web.create()` returns an empty router. `Web.addGet` and `Web.addPost` (and `addPut`, `addDelete`, `addPatch`) each return a new router with one additional route — routing configuration is immutable and every operation produces a new value. `Web.start()` hands the router to the configured backend and blocks until the process receives a shutdown signal.

### §23.2.3 Composing routers

For larger services, group related routes into sub-routers and merge them:

```lyric
val userRouter  = Web.prefix(MyService.Handlers.userRouter(),  "/users")
val adminRouter = Web.prefix(MyService.Admin.adminRouter(),    "/admin")
val router      = Web.merge(userRouter, adminRouter)
Web.start(router)
```

`Web.prefix(router, path)` prepends `path` to every route in `router`. `Web.merge(a, b)` concatenates two routers into one; if the same method and path appear in both, the second registration takes precedence and the compiler emits a warning at the call site. The pattern of one `*Router()` function per package — returning a `Router` that the entry point merges — keeps route registration close to the handlers it covers.

::: sidebar
**Handler functions are just functions.** The routing annotations (`@get`, `@post`, and so on) are metadata; they do not change the calling convention. A handler can be called directly in a unit test, without constructing a router or starting a server. Pass values for each parameter and check the `Result` — the full function body, including the `requires:` clause, runs exactly as it would under HTTP. This is why handler tests in Lyric look identical to tests for any other function.
:::

## §23.3 `ApiError` — the error type

`ApiError` is a `pub record` in the `Web` package that carries an HTTP status code, a human-readable message, and an optional structured detail payload. You never construct it directly; the helper functions in `Web` produce the right status code automatically:

| Constructor | Status |
|---|---|
| `Web.badRequest(msg)` | 400 |
| `Web.badRequestWithDetail(msg, fields)` | 400 with field-level detail |
| `Web.unauthorized(msg)` | 401 |
| `Web.forbidden(msg)` | 403 |
| `Web.notFound(msg)` | 404 |
| `Web.conflict(msg)` | 409 |
| `Web.unprocessable(msg, detail)` | 422 |
| `Web.tooManyRequests(msg)` | 429 |
| `Web.internalError(msg)` | 500 |
| `Web.apiError(status, msg)` | any status in 100..=599 |

The `badRequestWithDetail` and `unprocessable` variants accept an optional second argument: a list of `{ field: String; message: String }` records that the client can use to highlight specific form fields or request properties that failed validation. Use `Web.apiError` for protocol-level status codes that the other constructors do not cover — redirects, custom gateway codes, and so on.

`ApiError` serializes as a JSON object with a stable shape:

```json
{
  "status": 404,
  "message": "user 99 not found"
}
```

or, with a detail list:

```json
{
  "status": 400,
  "message": "validation failed",
  "detail": [
    { "field": "email", "message": "must be a valid address" }
  ]
}
```

Clients can treat the shape as a contract. The `status` field always matches the HTTP response code.

## §23.4 Runtime configuration

`lyric-web` uses two `config` blocks — `Server` and `Cors` — that follow the same rules as any other Lyric config block (Chapter 11 §11.2). Values are populated from environment variables at startup. You do not need to write any configuration-reading code.

### §23.4.1 Server configuration

Environment-variable prefix: `LYRIC_CONFIG_WEB_SERVER_`

| Variable suffix | Type | Default | Meaning |
|---|---|---|---|
| `HOST` | String | `0.0.0.0` | Bind address |
| `PORT` | Int (1..=65535) | `8080` | TCP port |
| `SWAGGERENABLED` | Bool | `false` | Serve Swagger UI and live spec |
| `SPECPATH` | String | `/openapi.json` | URL path for the live OpenAPI spec |

Set `LYRIC_CONFIG_WEB_SERVER_PORT=9000` in your environment and the server binds to port 9000 with no code change. The `PORT` field is declared as a range subtype `Int range 1..=65535`, so a value like `0` or `99999` is rejected at startup with a clear error rather than producing a silent bind failure.

Setting `SWAGGERENABLED=true` activates the Swagger UI at `/swagger` and serves the live OpenAPI spec document at `SPECPATH`. The spec is generated from the annotations on your handler functions and the types in your router. You do not maintain a spec file by hand; it is derived from the code.

### §23.4.2 CORS configuration

Environment-variable prefix: `LYRIC_CONFIG_WEB_CORS_`

| Variable suffix | Type | Default | Meaning |
|---|---|---|---|
| `ENABLED` | Bool | `false` | Enable CORS middleware |
| `ALLOWEDORIGINS` | String | `*` | Comma-separated allowed origins |
| `ALLOWEDMETHODS` | String | `GET,POST,PUT,DELETE,OPTIONS,PATCH` | Comma-separated allowed methods |
| `ALLOWEDHEADERS` | String | `Content-Type,Authorization,Accept` | Comma-separated allowed headers |
| `MAXAGESECONDS` | Int | `86400` | Preflight response cache duration in seconds |

CORS is disabled by default. Set `LYRIC_CONFIG_WEB_CORS_ENABLED=true` to activate the middleware. In production, set `ALLOWEDORIGINS` to the specific origin or origins your frontend uses rather than leaving the wildcard default.

::: note
**Note:** The `ALLOWEDORIGINS`, `ALLOWEDMETHODS`, and `ALLOWEDHEADERS` variables accept comma-separated strings at the environment level. The `config` block parses them into `[String]` at startup, so the values are validated and accessible as lists in any code that reads the config — there is no string splitting in your application code.
:::

## §23.5 Authentication and rate limiting

`Web.Aspects` provides two aspect templates: `RequiresAuth` and `RateLimit`. An aspect template is a parameterised cross-cutting concern; you instantiate it by declaring an `aspect` in your package that names the template and provides configuration. Aspect weaving is part of the M1.4 work tracked in the implementation plan.

### §23.5.1 `RequiresAuth`

`RequiresAuth` is a C-mode aspect (it rewrites the call site) that validates a JWT before the handler body runs. Instantiate it with a `matches:` clause that selects which handlers it applies to:

```lyric
import Web.Aspects

aspect Auth from Web.Aspects.RequiresAuth {
  matches: name like "handle*"
  except name in { handleHealth }
}
```

`matches: name like "handle*"` applies the aspect to every function whose name starts with `handle`. The `except` clause excludes `handleHealth` — a health-check endpoint that should remain unauthenticated.

Configuration for the `Auth` instance flows from `config { }` blocks backed by environment variables with the prefix `LYRIC_CONFIG_ASPECTS_AUTH_`:

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `enabled` | Bool | No | `true` | Disable the aspect without removing it |
| `jwtSecret` | String | Yes (`@sensitive`) | — | Secret for JWT signature verification |
| `issuer` | String | No | `""` | Expected `iss` claim; any issuer accepted if empty |
| `audience` | String | No | `""` | Expected `aud` claim; any audience accepted if empty |

`jwtSecret` is declared `@sensitive`, which means the config system never logs or includes it in diagnostics output. Omitting it when `enabled = true` is a startup error.

Any handler covered by `RequiresAuth` must declare an `authToken: String` parameter. The compiler emits diagnostic **A0042** at the handler site if the parameter is absent — the aspect cannot inject the token into a function that has no place to receive it:

```
myService.l:14:1: error A0042: handler 'handleCreateOrder' is covered by 'Auth' but
  declares no 'authToken: String' parameter
  note: add 'authToken: in String' to the parameter list, or exclude the function
        with 'except name in { handleCreateOrder }'
```

At runtime, the aspect:

- Returns 401 if the `Authorization` header is absent or the scheme is not `Bearer`.
- Returns 403 if the token is present but invalid (signature failure, expired, wrong issuer or audience).
- Passes the raw token string into `authToken` and calls the handler body if validation succeeds.

### §23.5.2 `RateLimit`

`RateLimit` is a B-mode aspect (it wraps the call) that enforces a per-client request budget. Declare it inside the `Auth` aspect so rate limiting runs only on authenticated requests:

```lyric
aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "handle*"
  inside: Auth
  config { requestsPerMinute: Int = 30 }
}
```

The `inside: Auth` clause means `Throttle` is applied inside the `Auth` wrapper, so the rate-limit counter is keyed on the authenticated identity, not the raw IP address. Removing `inside: Auth` shifts the key to the client IP.

Configuration prefix `LYRIC_CONFIG_ASPECTS_THROTTLE_`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | Bool | `true` | Disable without removing |
| `requestsPerMinute` | Int | `60` | Sustained request budget per identity |
| `burstSize` | Int | `10` | Token-bucket burst allowance |

When the budget is exhausted the aspect returns a 429 response using `Web.tooManyRequests`. The handler body is not called. The `Retry-After` header is set to the number of seconds until the next token is available.

## §23.6 Spec-first workflow

If you have an existing OpenAPI 3.1 specification — perhaps because you are building a service that must satisfy a published API contract — you can generate handler stubs and types from it instead of writing them by hand:

```sh
lyric generate openapi spec.yaml --out src/generated/
```

The generator produces three files under `src/generated/`:

- `types.l` — record and enum types derived from OpenAPI component schemas.
- `handlers.l` — handler stub functions with `@get` / `@post` / ... annotations and `requires:` clauses derived from OpenAPI parameter constraints.
- `router.l` — a `router()` function that registers all generated handlers.

The generated stubs have empty bodies that return `Err(Web.internalError("not implemented"))`. Fill them in with your business logic; the generator will not overwrite files that already exist unless you pass `--force`.

OpenAPI types map to Lyric types as follows:

| OpenAPI type | Lyric type |
|---|---|
| `integer` / `int32` | `Int` |
| `integer` / `int64` | `Long` |
| `number` / `float` | `Float` |
| `string` | `String` |
| `string` (nullable) | `Option[String]` |
| `string` with `enum` | `pub enum T { ... }` |
| `object` | `pub record T { ... }` |
| `array` of T | `[T]` |

Numeric constraints (`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`) become range subtypes where possible — an integer parameter with `minimum: 1` and `maximum: 100` becomes `Int range 1..=100` — and `requires:` clauses where the constraint cannot be expressed as a range subtype (for example, `multipleOf`).

::: note
**Note:** The generator targets OpenAPI 3.1. OpenAPI 2.x (Swagger) is not supported directly; tools like `swagger2openapi` convert 2.x documents to 3.x before passing them to the generator.
:::

## §23.7 Full composition example

This section puts everything together: a service with authentication, rate limiting, CORS enabled for a known frontend origin, Swagger UI active in non-production deployments, and a merged router built from two handler packages.

```lyric
package MyService

import Std.Core
import Web
import Web.Aspects
import MyService.UserHandlers
import MyService.AdminHandlers

// Authentication: required on all handlers whose names start with "handle",
// except the health-check endpoint.
aspect Auth from Web.Aspects.RequiresAuth {
  matches: name like "handle*"
  except name in { handleHealth }
}

// Rate limiting: runs inside Auth so the counter is per authenticated identity.
aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "handle*"
  inside: Auth
  config { requestsPerMinute: Int = 60 }
}

func main(): Unit {
  val users  = Web.prefix(MyService.UserHandlers.router(),  "/users")
  val admin  = Web.prefix(MyService.AdminHandlers.router(), "/admin")
  val router = Web.merge(users, admin)
  Web.start(router)
}
```

Runtime configuration for this deployment (set these environment variables before starting the process):

```sh
# Server: bind on port 8443, enable Swagger UI
LYRIC_CONFIG_WEB_SERVER_PORT=8443
LYRIC_CONFIG_WEB_SERVER_SWAGGERENABLED=true
LYRIC_CONFIG_WEB_SERVER_SPECPATH=/openapi.json

# CORS: allow requests from the known frontend origin
LYRIC_CONFIG_WEB_CORS_ENABLED=true
LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS=https://app.example.com
LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS=GET,POST,PUT,DELETE,OPTIONS

# Auth: JWT validation (value kept in a secrets manager, injected at deploy time)
LYRIC_CONFIG_ASPECTS_AUTH_JWTSECRET=<value from secrets manager>
LYRIC_CONFIG_ASPECTS_AUTH_ISSUER=https://auth.example.com
LYRIC_CONFIG_ASPECTS_AUTH_AUDIENCE=myservice

# Rate limiting: tighter budget for this deployment
LYRIC_CONFIG_ASPECTS_THROTTLE_REQUESTSPERMINUTE=30
LYRIC_CONFIG_ASPECTS_THROTTLE_BURSTSIZE=5
```

Nothing in the source code changes between environments. The `SWAGGERENABLED` flag is false by default, so Swagger UI is absent from production builds without any code branch. The JWT secret never appears in source; it is injected at deployment. CORS origins are deployment-specific and live in the environment. This is the intended usage pattern: code is environment-agnostic; configuration is environment-specific.

::: sidebar
**Why environment variables and not a config file?** Lyric's `config { }` blocks follow the Twelve-Factor App convention: process environment is the right place for deployment-specific values. Files in the source tree tend to accumulate environment-specific content, get committed, and leak into builds or version history. Environment injection keeps secrets out of the repository and makes each deployment's configuration explicit at the process boundary. If you need a file-based layer — for local development convenience — a tool like `direnv` or a shell script that exports the variables before starting the process is the right layer, not a language feature.
:::

The `UserHandlers` and `AdminHandlers` packages each look like the handler package shown in §23.2.1. Their `router()` functions register routes and return a `Router` value; the entry point merges them and hands the merged router to `Web.start()`. Adding a new package of handlers means adding one `Web.prefix(...)` call in `main` and one `import`. The auth and rate-limiting aspects apply automatically to any handler function whose name matches the `like "handle*"` predicate — no per-handler annotation is needed.

## Exercises

1. **Add a new route.** Take the example from §23.2 and add a `@put("/users/{id}")` handler that updates an existing user. The handler should return `Web.notFound` if no user exists for the given id and `Web.conflict` if the updated name conflicts with an existing user. Write a unit test that calls the handler function directly (without a router or server) and checks the `Result` for each case.

2. **Configure CORS for local development.** Start with CORS disabled (the default). Enable it by setting `LYRIC_CONFIG_WEB_CORS_ENABLED=true` and `LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS=http://localhost:3000`. Verify that a preflight `OPTIONS` request to one of your routes returns an `Access-Control-Allow-Origin` header with the expected value. Then change `ALLOWEDORIGINS` to a different origin and confirm the header updates without recompiling.

3. **Try the spec-first workflow.** Write a minimal OpenAPI 3.1 specification with two endpoints — a `GET /items/{id}` and a `POST /items` — including a request body schema with at least one `minimum` constraint. Run `lyric generate openapi spec.yaml --out src/generated/`. Open the generated `handlers.l` and compare the `requires:` clauses on the stubs to the constraints in the spec. Fill in one stub with a real implementation and run `lyric build`.

4. **Explore `ApiError` constructors.** Write a function that accepts an `Int` representing an HTTP status code and returns an appropriate `ApiError` using the named constructors where one exists and `Web.apiError` for the rest. Which constructors do you need? What happens if you pass a status code outside the 100..=599 range to `Web.apiError`?

5. **Auth aspect parameter requirement.** Declare a handler function that matches the `like "handle*"` predicate for `RequiresAuth` but omit the `authToken: String` parameter from its signature. Build the project and read the A0042 diagnostic. Then exclude the function using the `except name in { ... }` clause and confirm the diagnostic disappears.
