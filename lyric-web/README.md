# lyric-web

OpenAPI-first HTTP web service library for [Lyric](https://github.com/nichobbs/lyric-lang).  Ships typed routing, runtime configuration, CORS middleware, and aspect templates for authentication and rate limiting.  Supports both **code-first** (write handlers, generate the spec) and **spec-first** (import a spec, implement the stubs) development.

> **Status**: Library source and type vocabulary are complete.  The HTTP kernel dispatch (ASP.NET Core Kestrel integration via `Web.Kernel.Net`) and the aspect weaver are planned compiler / runtime milestones.  The library can be imported, routers built, and aspects instantiated today; HTTP serving and weaving take effect once those milestones ship.

## Platform parity

| Feature flag | Backend                                              | Status                |
|--------------|------------------------------------------------------|-----------------------|
| `dotnet`     | ASP.NET Core / Kestrel via `Web.Kernel.Net`          | Available             |
| `jvm`        | Undertow (`io.undertow:undertow-core`) via `Web.Kernel.Jvm` | Planned (Phase 6) |

`Web.Kernel.Jvm` declares the Undertow bindings plus a
`lyric.web.RateLimiter` helper supplied by the Lyric JVM stdlib JAR
(out-of-repo).  Until that JAR ships, only the `dotnet` feature
produces a runnable artifact.

## Packages

| Package | Description |
|---|---|
| `Web` | Core: `ApiError`, `Router`, `Header`, `Route`, server entry point, runtime config |
| `Web.OpenApi` | OpenAPI 3.1 spec types (`Spec`, `Schema`, `Operation`, …) and spec builder |
| `Web.Aspects` | Template aspects: `RequiresAuth`, `RateLimit` |
| `Web.Kernel.Net` | ASP.NET Core / Kestrel extern boundary (`@cfg feature = "dotnet"`) |

## Installation

```toml
[dependencies]
"Lyric.Web" = { path = "../lyric-web" }

[features]
dotnet = []    # enable the Kestrel backend
```

---

## Code-first workflow

### 1. Write annotated handlers

```lyric
package MyService.Handlers

import Std.Core
import Web

/// Retrieve a user by ID.
@get("/users/{id}")
@tag("users")
pub func getUser(
  id: in Int
): Result[User, ApiError]
  requires: id > 0
{
  match UserRepo.findById(id) {
    case Some(user) -> Ok(user)
    case None       -> Err(Web.notFound("user " + id.toString() + " not found"))
  }
}

/// Create a new user.
@post("/users")
@tag("users")
pub func createUser(
  @body req: in CreateUserRequest
): Result[User, ApiError]
  requires: req.name.length > 0
  requires: req.email.length > 0
{
  match UserRepo.insert(req) {
    case Ok(user) -> Ok(user)
    case Err(e)   -> Err(Web.conflict(e.message))
  }
}
```

### 2. Build the router and start

```lyric
package MyService

import Std.Core
import Web
import MyService.Handlers

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router,    "/users/{id}", "MyService.Handlers.getUser")
  router = Web.addPost(router,   "/users",      "MyService.Handlers.createUser")
  Web.start(router)
}
```

For multiple packages, compose routers:

```lyric
val userRouter  = Web.prefix(MyService.Handlers.userRouter(),  "/users")
val adminRouter = Web.prefix(MyService.Admin.adminRouter(),    "/admin")
val router      = Web.merge(userRouter, adminRouter)
Web.start(router)
```

### 3. Extract the OpenAPI spec

```sh
lyric build --manifest lyric.toml
lyric web spec --output openapi.yaml    # reads compiled DLL + Lyric.Contract resources
```

### 4. (Optional) Serve Swagger UI at runtime

```sh
export LYRIC_CONFIG_WEB_SERVER_SWAGGERENABLED=true
./myservice
# GET /openapi.json  → live OpenAPI 3.1 JSON
# GET /swagger       → Swagger UI
```

---

## Spec-first workflow

### 1. Generate stubs from a spec file

```sh
lyric generate openapi spec.yaml --out src/generated/
```

The generator reads the spec and emits:

- **Record types** for each `components/schemas` entry.
- **Handler stubs** for each path operation, one file per tag (or `handlers.l` if no tags).
- **Router helper** — a `router()` function that registers all generated handlers.

### 2. OpenAPI → Lyric type mapping

| OpenAPI schema | Lyric type generated |
|---|---|
| `type: integer, format: int32` | `Int` |
| `type: integer, format: int64` | `Long` |
| `type: number, format: float` | `Float` |
| `type: number, format: double` | `Double` |
| `type: boolean` | `Bool` |
| `type: string` | `String` |
| `type: string, nullable: true` | `Option[String]` |
| `type: string, enum: [a, b]` | generated `pub enum T { case A; case B }` |
| `type: object, properties: {…}` | generated `pub record T { field: Type; … }` |
| `type: array, items: T` | `[T]` |
| `$ref: '#/components/schemas/X'` | `X` (the generated Lyric type for schema `X`) |
| required property missing default | field without `=` default (callers must supply) |
| optional property | `Option[T]` field |

### 3. OpenAPI constraints → `requires:` clauses

When `minimum`, `maxLength`, etc. are present on a parameter the generator
emits a matching `requires:` clause, bridging the OpenAPI constraint to Lyric's
contract system.  The same clause becomes both a runtime check (framework returns
400 if violated) and a proof obligation in `@proof_required` packages.

| OpenAPI constraint | Generated `requires:` |
|---|---|
| `minimum: N` | `requires: param >= N` |
| `maximum: N` | `requires: param <= N` |
| `exclusiveMinimum: N` | `requires: param > N` |
| `exclusiveMaximum: N` | `requires: param < N` |
| `minLength: N` | `requires: param.length >= N` |
| `maxLength: N` | `requires: param.length <= N` |
| `minItems: N` | `requires: param.length >= N` |
| `maxItems: N` | `requires: param.length <= N` |
| `minimum + maximum together` | emits an `Int range N..=M` subtype instead |
| `pattern: "regex"` | `// TODO: validate pattern "regex"` comment (not expressible in v1 requires:) |

### 4. Example: spec in, stubs out

Spec fragment:

```yaml
/users/{id}:
  get:
    operationId: getUser
    tags: [users]
    parameters:
      - name: id
        in: path
        required: true
        schema: { type: integer, minimum: 1 }
    responses:
      200:
        content:
          application/json:
            schema: { $ref: '#/components/schemas/User' }
      404:
        description: Not found
```

Generated stub (`src/generated/users.l`):

```lyric
package MyService.Generated.Users

import Std.Core
import Web

@get("/users/{id}")
@tag("users")
pub func getUser(
  id: in Int
): Result[User, ApiError]
  requires: id >= 1    // generated from minimum: 1
{
  // TODO: implement
  Err(Web.internalError("not implemented"))
}
```

---

## Runtime configuration

All config fields are env-var-backed, read once at startup, fail-fast if a required field is missing.

### Server

| Env var | Type | Default | Description |
|---|---|---|---|
| `LYRIC_CONFIG_WEB_SERVER_HOST` | `String` | `0.0.0.0` | Bind address |
| `LYRIC_CONFIG_WEB_SERVER_PORT` | `Int` | `8080` | TCP port (1–65535) |
| `LYRIC_CONFIG_WEB_SERVER_SWAGGERENABLED` | `Bool` | `false` | Serve Swagger UI + live spec |
| `LYRIC_CONFIG_WEB_SERVER_SPECPATH` | `String` | `/openapi.json` | URL path for live spec |

### CORS

| Env var | Type | Default | Description |
|---|---|---|---|
| `LYRIC_CONFIG_WEB_CORS_ENABLED` | `Bool` | `false` | Enable CORS middleware |
| `LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS` | `String` | `*` | Comma-separated origins |
| `LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS` | `String` | `GET,POST,PUT,DELETE,OPTIONS,PATCH` | Comma-separated methods |
| `LYRIC_CONFIG_WEB_CORS_ALLOWEDHEADERS` | `String` | `Content-Type,Authorization,Accept` | Comma-separated headers |
| `LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS` | `Int` | `86400` | Preflight cache duration |

---

## Aspect templates

### `Web.Aspects.RequiresAuth`

Validates a Bearer JWT on every matched handler.  **C-mode** (`@inline_template`): reads `args.authToken` from the handler's parameter list — apply only to handlers that declare an `authToken: String` parameter.

```lyric
import Web.Aspects

aspect Auth from Web.Aspects.RequiresAuth {
  matches: name like "handle*"
  except name in { handleHealth, handleOpenApiSpec }
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

Enforces a per-endpoint sliding-window rate limit.  **B-mode**: uses `call.qualifiedName` as the bucket key.

```lyric
aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "handle*"
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

---

## Full composition example

```lyric
package MyService

import Std.Core
import Web
import Web.Aspects

// Outer → inner: Throttle > Auth > target
aspect Auth from Web.Aspects.RequiresAuth {
  matches: name like "handle*"
  except name in { handleHealth }
}

aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "handle*"
  inside:  Auth
  config { requestsPerMinute: Int = 120 }
}

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router,  "/health",     "MyService.Handlers.handleHealth")
  router = Web.addGet(router,  "/users/{id}", "MyService.Handlers.handleGetUser")
  router = Web.addPost(router, "/users",      "MyService.Handlers.handleCreateUser")
  Web.start(router)
}
```

Operator env:

```sh
export LYRIC_CONFIG_WEB_SERVER_PORT=443
export LYRIC_CONFIG_WEB_CORS_ENABLED=true
export LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS=https://myapp.example.com
export LYRIC_ASPECT_AUTH_JWTSECRET="$(cat /run/secrets/jwt_secret)"
export LYRIC_ASPECT_THROTTLE_REQUESTSPERMINUTE=60
```

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
| `apiError(status, msg)` | any | Custom status code (100–599) |

---

## Package layout

```
lyric-web/
  lyric.toml                      package manifest
  README.md                       this file
  src/
    web.l                         Web  (ApiError, Router, config, start)
    openapi.l                     Web.OpenApi  (spec types + builder)
    aspects.l                     Web.Aspects  (RequiresAuth, RateLimit)
    _kernel/
      net/web_kernel.l            Web.Kernel.Net  (Kestrel + JWT + rate-limit externs)
```

## See also

- `docs/26-aspects.md` §18 — aspect template instantiation rules
- `docs/27-aspect-libraries.md` — cross-package aspect distribution
- `docs/25-config-blocks.md` — config block semantics (D046)
- `docs/03-decision-log.md` D053 — design decisions for this library
