# 35 — lyric-lambda library design

**Status:** Specced in D062.

This document describes the design of `lyric-lambda`, the AWS Lambda runtime
adapter for Lyric.  It covers the API Gateway event mapping, the custom event
source handler model, the kernel dispatch protocol, and the local development
story.

---

## 1. Goals

1. Let a Lyric service built with `lyric-web` deploy to Lambda with zero
   handler-code changes — the same `Web.Router` and handler functions work
   identically on Kestrel and on Lambda.
2. Support the full breadth of Lambda event sources (SQS, SNS, S3, EventBridge,
   DynamoDB Streams) with typed event records and a `LambdaContext`-aware
   handler model.
3. Use the AWS Lambda custom runtime protocol so no ASP.NET Core overhead
   appears in the cold-start path for non-HTTP workloads.
4. Provide a local development story (`feature = "local"`) that requires no
   AWS credentials and is compatible with `sam local invoke`.

---

## 2. Library structure

```
lyric-lambda/
  lyric.toml
  src/
    lambda.l              — Lambda, core types and serve() entry point
    apigw.l               — Lambda.ApiGw, API Gateway v1/v2/ALB event types
    events.l              — Lambda.Events, SQS/SNS/S3/EventBridge/DynamoDB types
    lambda_aspects.l      — Lambda.Aspects, EventLogging + DeadlineGuard
    _kernel/
      lambda_kernel_aws.l   — Lambda.Kernel.Runtime @cfg(feature="aws")
      lambda_kernel_local.l — Lambda.Kernel.Runtime @cfg(feature="local")
```

Package names:

| Package | File | Purpose |
|---|---|---|
| `Lambda` | `lambda.l` | Core types, app builder, `serve()` |
| `Lambda.ApiGw` | `apigw.l` | API Gateway / ALB event types, `ApiGwResponse` |
| `Lambda.Events` | `events.l` | Non-HTTP event types and response helpers |
| `Lambda.Aspects` | `lambda_aspects.l` | `EventLogging`, `DeadlineGuard` templates |
| `Lambda.Kernel.Runtime` | `_kernel/*.l` | Extern boundary (one per feature) |

---

## 3. LambdaApp builder

`LambdaApp` is an immutable record built via a fluent API, following the same
pattern as `Web.Router`:

```lyric
import Lambda
import Lambda.Events
import Web

val router = Web.create()
  |> Web.addGet("/users/{id}", "MyApp.Users.getUser")
  |> Web.addPost("/users",     "MyApp.Users.createUser")

Lambda.serve(
  Lambda.newApp()
    |> Lambda.withRouter(router)          // API Gateway / ALB → lyric-web
    |> Lambda.onSqs("MyApp.Queue.handle") // SQS → custom handler
    |> Lambda.onS3("MyApp.Store.handle")) // S3  → custom handler
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
| `httpMethod` present AND `requestContext.resourceId` present | `ApiGwV1Event` |
| `requestContext.elb` present | `AlbEvent` |
| `Records[0].eventSource == "aws:sqs"` | `SqsEvent` |
| `Records[0].eventSource == "aws:sns"` | `SnsEvent` |
| `Records[0].eventSource == "aws:s3"` | `S3Event` |
| `Records[0].eventSource == "aws:dynamodb"` | `DynamoDbEvent` |
| `source` AND `detail-type` present | `EventBridgeEvent` |
| (none of the above) | Raw `String` |

### 4.2 HTTP event → Web.Router dispatch

When a HTTP event arrives and `LambdaApp.httpRouter` is `Some(router)`:

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

### 4.3 HTTP event without a router

If no `httpRouter` is configured and an HTTP event arrives, the kernel checks
`eventHandlers` for an `"apigw"` key.  If none is found, it responds with a
500 `InternalError`.  This lets advanced consumers register a raw HTTP handler:

```lyric
Lambda.serve(
  Lambda.newApp()
    |> Lambda.onRaw("MyApp.rawHandler"))
```

### 4.4 Binary payloads and base64

When `isBase64Encoded = true` on an incoming event, the kernel base64-decodes
the body before deserialising (or before passing it to the handler as raw bytes).
Handlers returning `ApiGwResponse.isBase64Encoded = true` have their body
base64-encoded in the Lambda response before posting to the runtime API.

---

## 5. Custom event source handlers

### 5.1 Registration

Handlers are registered by fully-qualified Lyric function name, mirroring
the `Web.Route.handlerName` pattern:

```lyric
Lambda.newApp()
  |> Lambda.onSqs("MyApp.Queue.handleBatch")
  |> Lambda.onS3("MyApp.Store.handleObjectEvent")
  |> Lambda.onEventBridge("MyApp.Scheduler.handleEvent")
  |> Lambda.onRaw("MyApp.Fallback.handle")
```

The kernel resolves each name via DLL reflection at startup.

### 5.2 Handler signatures

All custom handlers receive the deserialised event and a `LambdaContext`:

| Source | First param type | Return type |
|---|---|---|
| SQS | `Lambda.Events.SqsEvent` | `Result[Unit, Lambda.LambdaError]` or `Result[SqsBatchResponse, Lambda.LambdaError]` |
| SNS | `Lambda.Events.SnsEvent` | `Result[Unit, Lambda.LambdaError]` |
| S3 | `Lambda.Events.S3Event` | `Result[Unit, Lambda.LambdaError]` |
| EventBridge | `Lambda.Events.EventBridgeEvent` | `Result[Unit, Lambda.LambdaError]` |
| DynamoDB | `Lambda.Events.DynamoDbEvent` | `Result[Unit, Lambda.LambdaError]` |
| Raw | `String` | `Result[Unit, Lambda.LambdaError]` |

The second parameter is always `ctx: Lambda.LambdaContext`.

### 5.3 SQS partial-batch-failure

Returning `Result[SqsBatchResponse, LambdaError]` enables per-message failure
reporting.  The kernel serialises `batchItemFailures` into the Lambda response
body so only the failed messages are re-enqueued.

The SQS event source mapping must have `FunctionResponseTypes =
["ReportBatchItemFailures"]` for this to take effect.

### 5.4 Error serialisation

Handler errors are serialised as:

```json
{ "errorType": "FunctionError", "errorMessage": "<Lambda.errorMessage(err)>" }
```

and posted to the Lambda Runtime API error endpoint.  The runtime interprets
this as a handled invocation error (the Lambda fails the invocation and the
caller sees `FunctionError`).

---

## 6. Kernel design

### 6.1 Feature flag convention

Two files both declare `package Lambda.Kernel.Runtime`, each gated on a
different feature:

- `lambda_kernel_aws.l` — `@cfg(feature = "aws")` — production custom runtime
- `lambda_kernel_local.l` — `@cfg(feature = "local")` — local test server

Exactly one must be active per build.  The `lyric.toml` lists both in the
`Lambda.Kernel.Runtime` package slot as a multi-source list; the build system
compiles only the gated file(s).

### 6.2 Production runtime (feature = "aws")

The extern boundary calls `Amazon.Lambda.RuntimeSupport` 1.x, which handles
the HTTP polling loop, context extraction, and runtime API posting.  The
library is included as a NuGet dependency only when `feature = "aws"` is
active.

`localPort` is accepted but unused; the parameter is present to keep the
`serve()` signature uniform.

### 6.3 Local test server (feature = "local")

The `Lambda.LocalServer` extern starts a single-threaded HTTP server on
`localhost:{localPort}`.  Each `POST /2015-03-31/functions/function/invocations`
is processed synchronously:

1. Read the raw event JSON from the request body.
2. Run the same dispatch logic as the production kernel.
3. Write the Lambda response JSON as the HTTP response body.

A synthetic `LambdaContext` is injected per request:

| Field | Value |
|---|---|
| `functionName` | `"local-function"` |
| `functionVersion` | `"$LATEST"` |
| `invokedFunctionArn` | `"arn:aws:lambda:us-east-1:000000000000:function:local-function"` |
| `memoryLimitInMb` | `512` |
| `requestId` | random UUID |
| `logGroupName` | `"/aws/lambda/local-function"` |
| `logStreamName` | `"local"` |
| `remainingTimeMs` | `30000` (override via `LYRIC_LOCAL_TIMEOUT_MS`) |

---

## 7. Aspects

### 7.1 EventLogging (B-mode)

Wraps every matched handler call, records start time, proceeds, then logs
`handlerName outcome elapsedMs` at the configured level.  Composes with
`DeadlineGuard` as the outer aspect so deadline rejections are also logged.

```lyric
aspect LogAll from Lambda.Aspects.EventLogging {
  matches: name like "handle*"
}
```

### 7.2 DeadlineGuard (C-mode, @inline_template)

Checks `args.ctx.remainingTimeMs` before proceeding.  If `remainingTimeMs <=
thresholdMs`, returns `LambdaError.TimeoutError` without calling the handler.
Default threshold: 500 ms — enough time to log the rejection and return a
clean error before the runtime terminates the process.

```lyric
aspect GuardDeadline from Lambda.Aspects.DeadlineGuard {
  matches: name like "handle*"
  inside:  LogAll
  config {
    thresholdMs: Long = 1000
  }
}
```

The matched handler must declare `ctx: Lambda.LambdaContext`.  The compiler
reports shape error A0042 otherwise.

---

## 8. Runtime config

```
LYRIC_CONFIG_LAMBDA_RUNTIME_LOCALPORT   — local test server port (default: 9000)
```

All `Web.Server.*` and `Web.Cors.*` env vars apply when an `httpRouter` is
attached; the router reads them through the existing `Web` config blocks.

---

## 9. Additional design considerations

### 9.1 Cold start

The custom runtime (feature = "aws") avoids ASP.NET Core startup cost for
non-HTTP workloads.  For HTTP workloads (router attached), Kestrel is still
not in the picture — the kernel drives HTTP dispatch directly.  This reduces
cold start compared to `Amazon.Lambda.AspNetCoreServer`.

For workloads where cold start is critical, Native AOT (`PublishAot=true`) can
be enabled.  This conflicts with handler dispatch by DLL reflection.  When AOT
is used, handlers must be registered with a delegate rather than a string name.
A future `Lambda.onSqsDirect` / `Lambda.withRouterDirect` set of builders that
accept function references instead of strings would enable AOT compatibility;
this is tracked as Q-lambda-001.

### 9.2 Warm invocation state

Lambda reuses the same process across warm invocations.  Module-level values
(DB connection pools from `lyric-db`, HTTP clients from `Std.Http`) persist
across calls.  This is desirable for performance but requires handlers to be
designed for concurrent reuse:

- Connection pools from `lyric-db` are safe — they are designed for reuse.
- `Std.Http.clientWithRedirects()` returns a pooled `HttpClient` — safe to
  store at module level.
- Avoid capturing mutable state in handler closures.

### 9.3 VPC / network access

Lambda functions in a VPC can reach RDS, ElastiCache, and other VPC resources.
The `lyric-db` PostgreSQL driver works without change inside a VPC Lambda.
Cold starts in VPCs are slower due to ENI attachment; Lambda SnapStart is
not available for custom runtimes.

### 9.4 IAM permissions and secrets

Sensitive configuration (DB passwords, API keys) should flow through AWS
Secrets Manager or Parameter Store, not environment variables.  A future
`lyric-aws-secrets` library can expose a typed config-block override that
fetches secrets at startup, compatible with the `@sensitive` annotation used
by `Web.Aspects.RequiresAuth.jwtSecret`.  Tracked as Q-lambda-002.

### 9.5 Observability

`lyric-otel` structured logging writes to stdout, which Lambda forwards to
CloudWatch Logs automatically.  For distributed tracing, AWS X-Ray is
instrumented by adding the `XRAY_TRACE_ID` header parser to the kernel and
injecting trace context into `LambdaContext`.  Tracked as Q-lambda-003.

### 9.6 Response streaming

Lambda response streaming (available since 2023) reduces time-to-first-byte
for large HTTP responses by letting the handler write chunks before completing.
This requires `FunctionUrlAuthType` or a streaming-compatible API Gateway
integration.  The current kernel buffers the full response.  Streaming support
would require a `Stream.Writer` handle in the handler signature and is tracked
as Q-lambda-004.

---

## 10. Open questions

| ID | Question |
|---|---|
| Q-lambda-001 | AOT-compatible handler registration (function references instead of string names) |
| Q-lambda-002 | `lyric-aws-secrets` library for Secrets Manager / Parameter Store config-block integration |
| Q-lambda-003 | AWS X-Ray trace context propagation in `LambdaContext` |
| Q-lambda-004 | Response streaming for large HTTP payloads |
| Q-lambda-005 | Lambda authorizer (TOKEN / REQUEST) handler type and IAM policy response format |
| Q-lambda-006 | Kinesis stream event type (`Records[0].eventSource == "aws:kinesis"`) |
