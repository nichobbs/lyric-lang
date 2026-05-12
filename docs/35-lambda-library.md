# 35 — lyric-lambda and lyric-aws-secrets library design

**Status:** Specced in D062, D063.

This document describes the design of `lyric-lambda` (AWS Lambda runtime adapter)
and `lyric-aws-secrets` (Secrets Manager / Parameter Store config integration).

---

## 1. Goals

1. Let a Lyric service built with `lyric-web` deploy to Lambda with zero
   handler-code changes — the same `Web.Router` and handler functions work
   identically on Kestrel and on Lambda.
2. Support the full breadth of Lambda event sources (SQS, SNS, S3, EventBridge,
   DynamoDB Streams, Kinesis) with typed event records and a `LambdaContext`-aware
   handler model.
3. Support Lambda authorizer functions for both REST API (TOKEN / REQUEST, returning
   IAM policies) and HTTP API v2 (simple `isAuthorized` response).
4. Provide config-block-integrated secret injection from Secrets Manager and
   Parameter Store via `lyric-aws-secrets`.
5. Use the AWS Lambda custom runtime protocol so no ASP.NET Core overhead
   appears in the cold-start path for non-HTTP workloads.
6. Provide a local development story (`feature = "local"`) that requires no
   AWS credentials and is compatible with `sam local invoke`.

---

## 2. Library structure

### lyric-lambda

```
lyric-lambda/
  lyric.toml
  src/
    lambda.l              — Lambda, core types and serve() entry point
    apigw.l               — Lambda.ApiGw, API Gateway v1/v2/ALB event types
    events.l              — Lambda.Events, SQS/SNS/S3/EventBridge/DynamoDB/Kinesis
    authorizer.l          — Lambda.Authorizer, TOKEN/REQUEST/HTTP authorizer types
    lambda_aspects.l      — Lambda.Aspects, EventLogging + DeadlineGuard
    _kernel/
      lambda_kernel_aws.l   — Lambda.Kernel.Runtime @cfg(feature="aws")
      lambda_kernel_local.l — Lambda.Kernel.Runtime @cfg(feature="local")
```

| Package | File | Purpose |
|---|---|---|
| `Lambda` | `lambda.l` | Core types, `LambdaApp` builder, `serve()` |
| `Lambda.ApiGw` | `apigw.l` | API Gateway / ALB event types, `ApiGwResponse` |
| `Lambda.Events` | `events.l` | SQS, SNS, S3, EventBridge, DynamoDB, Kinesis |
| `Lambda.Authorizer` | `authorizer.l` | Authorizer event + response types and helpers |
| `Lambda.Aspects` | `lambda_aspects.l` | `EventLogging`, `DeadlineGuard` templates |
| `Lambda.Kernel.Runtime` | `_kernel/*.l` | Extern boundary (one per feature) |

### lyric-aws-secrets

```
lyric-aws-secrets/
  lyric.toml
  src/
    secrets.l             — AwsSecrets, annotations, init(), explicit fetch API
    _kernel/
      secrets_kernel_aws.l   — AwsSecrets.Kernel.Net @cfg(feature="aws")
      secrets_kernel_local.l — AwsSecrets.Kernel.Net @cfg(feature="local")
```

| Package | File | Purpose |
|---|---|---|
| `AwsSecrets` | `secrets.l` | Annotations, `SecretsError`, `init()`, `getSecret*`, `getParameter*` |
| `AwsSecrets.Kernel.Net` | `_kernel/*.l` | AWS SDK extern boundary (one per feature) |

---

## 3. LambdaApp builder

`LambdaApp` is an immutable record built via a fluent API:

```lyric
import Lambda
import Lambda.Events
import AwsSecrets
import Web

val router = Web.create()
  |> Web.addGet("/users/{id}", "MyApp.Users.getUser")
  |> Web.addPost("/users",     "MyApp.Users.createUser")

func main(): Int {
  match AwsSecrets.init() {
    Ok(_)    => Lambda.serve(
      Lambda.newApp()
        |> Lambda.withRouter(router)               // API Gateway / ALB → lyric-web
        |> Lambda.onSqs("MyApp.Queue.handle")      // SQS → custom handler
        |> Lambda.onTokenAuthorizer("MyApp.Auth.verify")) // REST API authorizer
    Err(err) => {
      Std.Core.log("ERROR", AwsSecrets.errorMessage(err))
      return 1
    }
  }
  return 0
}
```

`LambdaApp` has three fields, all optional:

```lyric
pub record LambdaApp {
  httpRouter:         Option[Web.Router]
  eventHandlers:      [EventHandler]
  authorizerHandlers: [AuthorizerHandler]
}
```

`serve()` reads `Lambda.Runtime.localPort` from env and calls the kernel.

---

## 4. API Gateway event mapping

### 4.1 Payload format detection

The kernel identifies the event type by inspecting the raw JSON before
deserialising:

| Detection rule | Event type |
|---|---|
| `version == "2.0"` AND `requestContext.http` present | `ApiGwV2Event` |
| `httpMethod` AND `requestContext.resourceId` present | `ApiGwV1Event` |
| `requestContext.elb` present | `AlbEvent` |
| `Records[0].eventSource == "aws:sqs"` | `SqsEvent` |
| `Records[0].eventSource == "aws:sns"` | `SnsEvent` |
| `Records[0].eventSource == "aws:s3"` | `S3Event` |
| `Records[0].eventSource == "aws:dynamodb"` | `DynamoDbEvent` |
| `Records[0].eventSource == "aws:kinesis"` | `KinesisEvent` |
| `source` AND `detail-type` present | `EventBridgeEvent` |
| `type == "TOKEN"` AND `authorizationToken` present | `TokenAuthorizerEvent` |
| `type == "REQUEST"` AND `methodArn` present (no `routeArn`) | `RequestAuthorizerEvent` |
| `type == "REQUEST"` AND `routeArn` present | `HttpAuthorizerEvent` |
| (none of the above) | Raw `String` |

### 4.2 HTTP event → Web.Router dispatch

When an HTTP event arrives and `LambdaApp.httpRouter` is `Some(router)`:

1. Extract `method`, `path`, `headers`, `query`, and `body` from the event
   (normalised across v1/v2/ALB shapes).
2. Run the router's match-and-dispatch logic (same mechanism as Kestrel).
3. Serialise `Result[T, Web.ApiError]` to `ApiGwResponse`:
   - `Ok(value)` → `statusCode 200`, JSON body, `Content-Type: application/json`
   - `Err(e)` → `statusCode e.status`, body `{ "error": msg, "detail": [...] }`
4. Apply CORS headers if `Web.Cors.enabled = true`.

For v1 events the kernel uses `path` and `httpMethod` directly.
For v2 events it uses `rawPath` and `requestContext.http.method`.
For ALB events it uses `path` and `httpMethod`.

Multi-value headers from v1/ALB are reflected in `ApiGwResponse.multiValueHeaders`.
v2 headers (comma-joined per RFC 7230) are passed as single-value.

### 4.3 Binary payloads and base64

When `isBase64Encoded = true` on an incoming event, the kernel base64-decodes
the body before deserialising.  Handlers returning `ApiGwResponse.isBase64Encoded
= true` have their body base64-encoded in the Lambda response.

---

## 5. Custom event source handlers

### 5.1 Registration and handler signatures

| Builder | Event source key | First param type | Return type |
|---|---|---|---|
| `onSqs` | `"aws:sqs"` | `SqsEvent` | `Result[Unit\|SqsBatchResponse, LambdaError]` |
| `onSns` | `"aws:sns"` | `SnsEvent` | `Result[Unit, LambdaError]` |
| `onS3` | `"aws:s3"` | `S3Event` | `Result[Unit, LambdaError]` |
| `onEventBridge` | `"aws.events"` | `EventBridgeEvent` | `Result[Unit, LambdaError]` |
| `onDynamoDb` | `"aws:dynamodb"` | `DynamoDbEvent` | `Result[Unit, LambdaError]` |
| `onKinesis` | `"aws:kinesis"` | `KinesisEvent` | `Result[Unit, LambdaError]` |
| `onRaw` | `"raw"` | `String` | `Result[Unit, LambdaError]` |

The second parameter is always `ctx: Lambda.LambdaContext`.

### 5.2 SQS partial-batch-failure

Returning `Result[SqsBatchResponse, LambdaError]` enables per-message failure
reporting.  The kernel serialises `batchItemFailures` into the Lambda response
body so only the failed messages are re-enqueued.

Requires the SQS event source mapping to have `FunctionResponseTypes =
["ReportBatchItemFailures"]`.

Kinesis does not support equivalent partial-failure reporting.  On error the
entire batch is retried until it succeeds or expires from the stream; design
Kinesis handlers to be idempotent on the partition key.

### 5.3 Error serialisation

Handler errors are serialised as:

```json
{ "errorType": "FunctionError", "errorMessage": "<Lambda.errorMessage(err)>" }
```

and posted to the Lambda Runtime API error endpoint.

---

## 6. Authorizers (`Lambda.Authorizer`)

### 6.1 Overview

A Lambda authorizer is a separate Lambda function invoked by API Gateway
before forwarding a request to the backend handler.  It returns either an IAM
policy document (REST API) or a simple allow/deny (HTTP API v2).

Register an authorizer handler in `main()` via the `LambdaApp` builder:

```lyric
Lambda.serve(
  Lambda.newApp()
    |> Lambda.onTokenAuthorizer("MyApp.Auth.verifyToken"))
```

### 6.2 REST API TOKEN authorizer

Receives `TokenAuthorizerEvent { authorizationToken, methodArn }`.
Returns `Result[AuthorizerResponse, LambdaError]`.

```lyric
func verifyToken(event: Lambda.Authorizer.TokenAuthorizerEvent, ctx: Lambda.LambdaContext)
    : Result[Lambda.Authorizer.AuthorizerResponse, Lambda.LambdaError] {
  val claims = parseJwt(event.authorizationToken)
  match claims {
    Ok(c)    => return Ok(
      Lambda.Authorizer.allowAll(c.sub, event.methodArn)
        |> Lambda.Authorizer.withContext(Map.of([("userId", c.sub), ("role", c.role)])))
    Err(msg) => return Ok(Lambda.Authorizer.deny("anonymous", event.methodArn))
  }
}
```

Helper constructors:
- `allow(principalId, methodArn)` — allow exactly the invoked method
- `allowAll(principalId, methodArn)` — allow all methods on the same stage
- `deny(principalId, methodArn)` — deny the invoked method
- `withContext(response, ctx)` — attach context forwarded to the backend
- `withUsageKey(response, key)` — set usage-plan API key

### 6.3 REST API REQUEST authorizer

Receives `RequestAuthorizerEvent` (full request context including headers,
query params, stage variables).  Returns the same `AuthorizerResponse` type.

Use REQUEST authorizers when the authorization decision depends on more than
a single header (e.g. combining an Authorization header with a custom
`X-Tenant-Id` header).

```lyric
Lambda.serve(
  Lambda.newApp()
    |> Lambda.onRequestAuthorizer("MyApp.Auth.verifyRequest"))
```

### 6.4 HTTP API (v2) authorizer

Receives `HttpAuthorizerEvent` (lightweight request context with resolved
identity source, route key, and headers).
Returns `Result[HttpAuthorizerResponse, LambdaError]`.

```lyric
func verifyHttpRequest(event: Lambda.Authorizer.HttpAuthorizerEvent, ctx: Lambda.LambdaContext)
    : Result[Lambda.Authorizer.HttpAuthorizerResponse, Lambda.LambdaError] {
  val ok = validateToken(event.identitySource)
  if ok {
    return Ok(Lambda.Authorizer.authorizedWithContext(Map.of([("userId", extractSub(event.identitySource))])))
  } else {
    return Ok(Lambda.Authorizer.denied())
  }
}
```

Helper constructors:
- `authorized()` — allow, no context
- `authorizedWithContext(ctx)` — allow, forward context map to backend
- `denied()` — deny (API Gateway returns 403 to the caller)

### 6.5 IAM policy document

`AuthorizerResponse` wraps an `IamPolicyDocument` with `IamStatement` entries.
The `allow` / `allowAll` / `deny` helpers produce the standard
`execute-api:Invoke` statements.  For custom multi-statement policies, build
`IamPolicyDocument` directly:

```lyric
val policy = Lambda.Authorizer.IamPolicyDocument(
  version   = "2012-10-17",
  statement = [
    Lambda.Authorizer.IamStatement(
      effect   = Lambda.Authorizer.IamEffect.Allow,
      action   = ["execute-api:Invoke"],
      resource = ["arn:aws:execute-api:us-east-1:123:abc/prod/GET/users/*"]),
    Lambda.Authorizer.IamStatement(
      effect   = Lambda.Authorizer.IamEffect.Deny,
      action   = ["execute-api:Invoke"],
      resource = ["arn:aws:execute-api:us-east-1:123:abc/prod/DELETE/*"]),
  ])
```

---

## 7. Secrets integration (`lyric-aws-secrets`)

### 7.1 Config-block annotation model

Apply `@secretsManager` or `@parameterStore` to any `@sensitive` field in a
config block.  Call `AwsSecrets.init()` once at process startup to fetch and
cache all annotated values.

```lyric
import AwsSecrets

config Database {
  host: String = "localhost"
  port: Int    = 5432
  @sensitive
  @secretsManager("my-service/prod", key: "dbPassword")
  password: String
}

config Auth {
  @sensitive
  @secretsManager("my-service/prod", key: "jwtSecret")
  jwtSecret: String

  @sensitive
  @parameterStore("/my-service/signing-key")
  signingKey: String
}
```

### 7.2 Startup wiring

Call `AwsSecrets.init()` before `Lambda.serve()` or `Web.start()`:

```lyric
func main(): Int {
  match AwsSecrets.init() {
    Ok(_)    => Lambda.serve(Lambda.newApp() |> Lambda.withRouter(router))
    Err(err) => {
      Std.Core.log("ERROR", AwsSecrets.errorMessage(err))
      return 1
    }
  }
  return 0
}
```

`init()` scans the compiled DLL for `@secretsManager` / `@parameterStore`
annotations on config fields, fetches each value from AWS, and stores it in
the process-level config cache under the same key used by env vars
(`LYRIC_CONFIG_<PACKAGE>_<FIELD>`).  The existing config-block access mechanism
then reads from the cache unchanged.

### 7.3 Env var override

If `LYRIC_CONFIG_<PACKAGE>_<FIELD>` is set, `init()` skips the AWS fetch for
that field and uses the env var value.  This enables local development without
AWS credentials: set env vars for the secrets you need locally and the library
works identically.

### 7.4 Annotations

| Annotation | Description |
|---|---|
| `@secretsManager("name")` | Fetch entire secret value (plain-string secret) |
| `@secretsManager("name", key: "field")` | Extract a JSON field from a structured secret |
| `@parameterStore("/path")` | Fetch a Parameter Store String or SecureString (auto-decrypted) |

### 7.5 Caching

Fetched values are cached in process memory for `SecretCache.ttlSeconds`
(default 300 s = 5 min).  On a warm Lambda invocation the cached value is
returned without an AWS SDK call.  Set `ttlSeconds = 0` to disable caching.

Rotation: choose `ttlSeconds < rotationPeriodSeconds / 6` so stale values
are refreshed well within the rotation window.

```
LYRIC_CONFIG_AWSSECRETS_SECRETCACHE_TTLSECONDS  — cache TTL (default: 300)
```

### 7.6 Explicit fetch API

For one-off fetches that don't fit a config field:

```lyric
val secret = AwsSecrets.getSecret("my-service/api-key")          // entire value
val field  = AwsSecrets.getSecretField("my-service/prod", "key") // JSON field
val param  = AwsSecrets.getParameter("/my/path")                  // Parameter Store
```

### 7.7 Local mode (feature = "local")

`init()` is a no-op in local mode — it scans annotations but skips all AWS
fetches.  Fields with env var overrides are populated from the env.  Fields
without overrides remain unset and produce a missing-config-value error when
first accessed, which surfaces missing local overrides explicitly.

`getSecret` / `getParameter` always return `SecretsError.NotFound` in local mode.

### 7.8 IAM requirements

The Lambda execution role must have:
- `secretsmanager:GetSecretValue` on target secrets
- `ssm:GetParameter` on target parameters
- `kms:Decrypt` on KMS keys protecting SecureString parameters

---

## 8. Kernel design

### 8.1 Feature flag convention

Two files both declare the same package name, each gated on a different feature.
Exactly one is compiled per build:

- `lambda_kernel_aws.l` — `@cfg(feature = "aws")` — production custom runtime
- `lambda_kernel_local.l` — `@cfg(feature = "local")` — local test server
- `secrets_kernel_aws.l` — `@cfg(feature = "aws")` — AWS SDK extern
- `secrets_kernel_local.l` — `@cfg(feature = "local")` — no-op local backend

### 8.2 Production Lambda runtime (feature = "aws")

The extern boundary calls `Amazon.Lambda.RuntimeSupport` 1.x, which handles
the HTTP polling loop, context extraction, and runtime API posting.  Authorizer
events are detected in the same dispatch pass as event source handlers.

### 8.3 Local test server (feature = "local")

`Lambda.LocalServer` starts a single-threaded HTTP server on
`localhost:{localPort}`.  Each `POST /2015-03-31/functions/function/invocations`
is processed synchronously and returns the Lambda response JSON.  Compatible
with `sam local invoke` and `aws lambda invoke --endpoint-url`.

Synthetic `LambdaContext`:

| Field | Value |
|---|---|
| `functionName` | `"local-function"` |
| `functionVersion` | `"$LATEST"` |
| `invokedFunctionArn` | `"arn:aws:lambda:us-east-1:000000000000:function:local-function"` |
| `memoryLimitInMb` | `512` |
| `requestId` | random UUID |
| `remainingTimeMs` | `30000` (override via `LYRIC_LOCAL_TIMEOUT_MS`) |

---

## 9. Aspects

### 9.1 EventLogging (B-mode)

Wraps every matched handler call, records start time, proceeds, then logs
`handlerName outcome elapsedMs` at the configured level.

```lyric
aspect LogAll from Lambda.Aspects.EventLogging {
  matches: name like "handle*"
}
```

### 9.2 DeadlineGuard (C-mode, @inline_template)

Checks `args.ctx.remainingTimeMs` before proceeding.  If `remainingTimeMs <=
thresholdMs`, returns `LambdaError.TimeoutError`.  Default threshold: 500 ms.

```lyric
aspect GuardDeadline from Lambda.Aspects.DeadlineGuard {
  matches: name like "handle*"
  inside:  LogAll
  config {
    thresholdMs: Long = 1000
  }
}
```

The matched handler must declare `ctx: Lambda.LambdaContext` (shape error A0042 otherwise).

---

## 10. Runtime config env vars

```
LYRIC_CONFIG_LAMBDA_RUNTIME_LOCALPORT           — local test server port (default: 9000)
LYRIC_CONFIG_AWSSECRETS_SECRETCACHE_TTLSECONDS  — secret cache TTL in seconds (default: 300)
LYRIC_LOCAL_TIMEOUT_MS                          — remainingTimeMs in synthetic context (default: 30000)
```

All `Web.Server.*` and `Web.Cors.*` env vars apply when an `httpRouter` is attached.

---

## 11. Additional design considerations

### 11.1 Cold start

The custom runtime avoids ASP.NET Core startup cost.  For HTTP workloads the
kernel drives dispatch directly without Kestrel, which reduces cold start
compared to `Amazon.Lambda.AspNetCoreServer`.

For workloads where cold start is critical, Native AOT (`PublishAot=true`) can
be enabled.  This conflicts with handler dispatch by DLL reflection; a future
`Lambda.onSqsDirect` / `withRouterDirect` API accepting function references
instead of strings would enable AOT compatibility.  Tracked as Q-lambda-001.

### 11.2 Warm invocation state

Lambda reuses the same process across warm invocations.  `lyric-db` connection
pools and `Std.Http` clients are safe to initialise at module level and reuse
across invocations.  Avoid capturing mutable state in handler closures.

### 11.3 Observability

`lyric-otel` structured logging writes to stdout, which Lambda forwards to
CloudWatch Logs.  AWS X-Ray active tracing is a separate concern best handled
at the infrastructure level (Lambda execution role + X-Ray daemon) rather than
in the library.  Tracked as Q-lambda-003.

### 11.4 Response streaming

Lambda response streaming reduces TTFB for large HTTP responses.  The current
kernel buffers the full response.  Streaming would require a `Stream.Writer`
handle in the handler signature.  Tracked as Q-lambda-004.

---

## 12. Open questions

| ID | Status | Question |
|---|---|---|
| Q-lambda-001 | Open | AOT-compatible handler registration (function references instead of string names) |
| Q-lambda-002 | **Resolved** — `lyric-aws-secrets` library shipped (D063) | |
| Q-lambda-003 | Open | AWS X-Ray trace context propagation — defer to infrastructure-level tracing |
| Q-lambda-004 | Open | Response streaming for large HTTP payloads |
| Q-lambda-005 | **Resolved** — `Lambda.Authorizer` shipped (D063) | |
| Q-lambda-006 | **Resolved** — `KinesisEvent` added to `Lambda.Events` (D063) | |
