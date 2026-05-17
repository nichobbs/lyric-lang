# 35 — lyric-lambda and lyric-aws-secrets library design

**Status:** Specced in D062, D063, D064.

This document describes the design of `lyric-lambda` (AWS Lambda runtime adapter),
`lyric-aws-secrets` (Secrets Manager / Parameter Store config integration), and
`lyric-aws-xray` (AWS X-Ray active tracing aspect).

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
7. Support Native AOT (`PublishAot=true`) via function-reference handler
   registration (`Lambda.Direct`) alongside the existing string-based API.
8. Support Lambda response streaming for Function URLs and HTTP API streaming
   via `Lambda.Stream.StreamWriter`.
9. Target the JVM (`feature = "jvm"`) using the AWS Java managed runtime
   (`RequestStreamHandler`) so the same source compiles to both .NET and JVM.
10. Provide AWS X-Ray active tracing as a B-mode pub aspect template via the
    separate `lyric-aws-xray` library.

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
    direct.l              — Lambda.Direct, AOT function-reference handler registration
    stream.l              — Lambda.Stream, StreamWriter + response streaming helpers
    lambda_aspects.l      — Lambda.Aspects, EventLogging + DeadlineGuard
    _kernel/
      lambda_kernel_aws.l   — Lambda.Kernel.Runtime @cfg(feature="aws")
      lambda_kernel_local.l — Lambda.Kernel.Runtime @cfg(feature="local")
      lambda_kernel_jvm.l   — Lambda.Kernel.Runtime @cfg(feature="jvm")
```

| Package | File | Purpose |
|---|---|---|
| `Lambda` | `lambda.l` | Core types, `LambdaApp` builder, `serve()` |
| `Lambda.ApiGw` | `apigw.l` | API Gateway / ALB event types, `ApiGwResponse` |
| `Lambda.Events` | `events.l` | SQS, SNS, S3, EventBridge, DynamoDB, Kinesis |
| `Lambda.Authorizer` | `authorizer.l` | Authorizer event + response types and helpers |
| `Lambda.Direct` | `direct.l` | AOT-safe handler registration via function references |
| `Lambda.Stream` | `stream.l` | `StreamWriter`, `write`, `writeBytes`, `close` |
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
      secrets_kernel_jvm.l   — AwsSecrets.Kernel.Net @cfg(feature="jvm")
```

| Package | File | Purpose |
|---|---|---|
| `AwsSecrets` | `secrets.l` | Annotations, `SecretsError`, `init()`, `getSecret*`, `getParameter*` |
| `AwsSecrets.Kernel.Net` | `_kernel/*.l` | AWS SDK extern boundary (one per feature) |

### lyric-aws-xray

```
lyric-aws-xray/
  lyric.toml
  src/
    xray.l                — AwsXRay, SubsegmentHandle, annotate(), metadata(), Tracing aspect
    _kernel/
      xray_kernel_aws.l   — AwsXRay.Kernel.Net @cfg(feature="aws")
      xray_kernel_jvm.l   — AwsXRay.Kernel.Net @cfg(feature="jvm")
      xray_kernel_local.l — AwsXRay.Kernel.Net @cfg(feature="local")
```

| Package | File | Purpose |
|---|---|---|
| `AwsXRay` | `xray.l` | `SubsegmentHandle`, `annotate`, `metadata`, `Tracing` aspect template |
| `AwsXRay.Kernel.Net` | `_kernel/*.l` | X-Ray SDK extern boundary (one per feature) |

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

`LambdaApp` has five fields, all optional:

```lyric
pub record LambdaApp {
  httpRouter:         Option[Web.Router]
  streamingHandler:   Option[String]
  eventHandlers:      [EventHandler]
  authorizerHandlers: [AuthorizerHandler]
  directHandlers:     [Lambda.Direct.DirectHandler]
}
```

`serve()` reads `Lambda.Runtime.localPort` from env and calls the kernel.

Builder methods:

| Method | Effect |
|---|---|
| `withRouter(app, router)` | Attach a `Web.Router`; HTTP events are dispatched through it |
| `withStreamingHandler(app, name)` | Register a streaming handler by qualified name; all HTTP events go here |
| `onSqs / onSns / onS3 / onEventBridge / onDynamoDb / onKinesis / onRaw` | Register a string-named event handler |
| `onTokenAuthorizer / onRequestAuthorizer / onHttpAuthorizer` | Register a string-named authorizer |
| `withDirect(app, handler)` | Register an AOT-safe `DirectHandler` (function reference) |

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

Multiple source files declare the same package name, each gated on a different
feature.  Exactly one is compiled per build:

| File | Feature | Description |
|---|---|---|
| `lambda_kernel_aws.l` | `aws` | .NET custom runtime (Amazon.Lambda.RuntimeSupport) |
| `lambda_kernel_local.l` | `local` | Lightweight local test HTTP server |
| `lambda_kernel_jvm.l` | `jvm` | Java managed runtime (RequestStreamHandler) |
| `secrets_kernel_aws.l` | `aws` | AWS SDK for .NET v3 |
| `secrets_kernel_local.l` | `local` | No-op local backend |
| `secrets_kernel_jvm.l` | `jvm` | AWS SDK for Java v2 |
| `xray_kernel_aws.l` | `aws` | Amazon.XRay.Recorder.Core (.NET) |
| `xray_kernel_jvm.l` | `jvm` | aws-xray-recorder-sdk-core (Java) |
| `xray_kernel_local.l` | `local` | No-op (subsegments silently dropped) |

### 8.2 Production Lambda runtime — .NET (feature = "aws")

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

### 8.4 JVM managed runtime (feature = "jvm")

On the JVM target, the Lyric JVM emitter generates a class
`<RootPackage>$LambdaHandler` implementing
`com.amazonaws.services.lambda.runtime.RequestStreamHandler`.

Set the Lambda function handler in the configuration to:
```
<assembly-name>.<RootPackage>$LambdaHandler::handleRequest
```

Dispatch is identical to the .NET kernel (event-source detection → typed
dispatch → serialised JSON response) but the OutputStream is used in place of
the Runtime API response endpoint.  Streaming handlers write directly to the
OutputStream without buffering; Function URL `InvokeMode` must be set to
`RESPONSE_STREAM`.

Maven dependencies added automatically when `feature = "jvm"`:
- `com.amazonaws:aws-lambda-java-core:1.2.3`
- `com.amazonaws:aws-lambda-java-events:3.11.4`

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

## 10. AOT-safe handler registration (`Lambda.Direct`)

`Lambda.Direct` provides function-reference factory functions for registering
handlers without DLL reflection.  Use `withDirect()` in place of (or alongside)
the string-based `on*()` builders when building with `PublishAot=true`.

### 10.1 Factory functions

```lyric
import Lambda.Direct

Lambda.newApp()
  |> Lambda.withDirect(Lambda.Direct.sqsHandler(MyApp.Queue.handle))
  |> Lambda.withDirect(Lambda.Direct.sqsBatchHandler(MyApp.Queue.handleBatch))
  |> Lambda.withDirect(Lambda.Direct.tokenAuthorizerHandler(MyApp.Auth.verify))
  |> Lambda.withDirect(Lambda.Direct.streamingHandler(MyApp.Llm.stream))
```

| Factory | Handler signature |
|---|---|
| `sqsHandler(h)` | `func(SqsEvent, LambdaContext) -> Result[Unit, LambdaError]` |
| `sqsBatchHandler(h)` | `func(SqsEvent, LambdaContext) -> Result[SqsBatchResponse, LambdaError]` |
| `snsHandler(h)` | `func(SnsEvent, LambdaContext) -> Result[Unit, LambdaError]` |
| `s3Handler(h)` | `func(S3Event, LambdaContext) -> Result[Unit, LambdaError]` |
| `eventBridgeHandler(h)` | `func(EventBridgeEvent, LambdaContext) -> Result[Unit, LambdaError]` |
| `dynamoDbHandler(h)` | `func(DynamoDbEvent, LambdaContext) -> Result[Unit, LambdaError]` |
| `kinesisHandler(h)` | `func(KinesisEvent, LambdaContext) -> Result[Unit, LambdaError]` |
| `rawHandler(h)` | `func(String, LambdaContext) -> Result[Unit, LambdaError]` |
| `tokenAuthorizerHandler(h)` | `func(TokenAuthorizerEvent, LambdaContext) -> Result[AuthorizerResponse, LambdaError]` |
| `requestAuthorizerHandler(h)` | `func(RequestAuthorizerEvent, LambdaContext) -> Result[AuthorizerResponse, LambdaError]` |
| `httpAuthorizerHandler(h)` | `func(HttpAuthorizerEvent, LambdaContext) -> Result[HttpAuthorizerResponse, LambdaError]` |
| `streamingHandler(h)` | `func(String, LambdaContext, StreamWriter) -> Result[Unit, LambdaError]` |

### 10.2 Mixing string-based and direct handlers

Both registration styles can coexist in the same `LambdaApp`.  The kernel
resolves `directHandlers` by stored delegate; `eventHandlers` by reflection.
When `PublishAot=true`, use `withDirect` exclusively — string-named handlers
will fail at startup because DLL reflection metadata is stripped.

---

## 11. Response streaming (`Lambda.Stream`)

Lambda response streaming delivers output chunks to the caller before the
handler returns, reducing time-to-first-byte for large or progressive responses.

### 11.1 Enabling streaming

Set `InvokeMode: RESPONSE_STREAM` on the Lambda Function URL, or use an
HTTP API streaming integration (check current AWS documentation for region
support).

Register via string name or `Lambda.Direct.streamingHandler`:

```lyric
Lambda.newApp()
  |> Lambda.withStreamingHandler("MyApp.Llm.streamTokens")
// or AOT-safe:
  |> Lambda.withDirect(Lambda.Direct.streamingHandler(MyApp.Llm.streamTokens))
```

### 11.2 Handler signature

```lyric
func streamTokens(rawEvent: String, ctx: Lambda.LambdaContext, writer: Lambda.Stream.StreamWriter)
    : Result[Unit, Lambda.LambdaError] {
  Lambda.Stream.setContentType(writer, "text/event-stream")
  val tokens = MyApp.Llm.generate(rawEvent)
  for token in tokens {
    match Lambda.Stream.write(writer, "data: " + token + "\n\n") {
      Ok(_)    => ()
      Err(err) => return Err(err)
    }
  }
  Lambda.Stream.close(writer)
  return Ok(())
}
```

`rawEvent` is the raw API Gateway / Function URL event JSON; parse it with
`Lambda.ApiGw` types if structured access is needed.

### 11.3 StreamWriter API

| Function | Description |
|---|---|
| `setContentType(writer, contentType)` | Set `Content-Type` before the first `write()` call; ignored after |
| `write(writer, chunk)` | Write a UTF-8 string chunk; delivers immediately |
| `writeBytes(writer, base64Chunk)` | Write raw bytes (base64-encoded input); decoded by the kernel |
| `close(writer)` | Signal end of response; called automatically on handler return |

After `close()` returns, further `write()` calls return
`LambdaError.InternalError`.

### 11.4 Constraints

- Do not mix `withStreamingHandler` and `withRouter` in the same `LambdaApp`.
  The streaming handler receives all HTTP traffic; the router is not consulted.
- The `Content-Type` header must be set before the first `write()`.
  If omitted, the kernel defaults to `application/octet-stream`.

---

## 12. JVM target (feature = "jvm")

All three libraries (`lyric-lambda`, `lyric-aws-secrets`, `lyric-aws-xray`)
support the `jvm` feature.  Build with `lyric build --features jvm` to target
the AWS Java managed runtime.

### 12.1 Build output

The Lyric JVM emitter (complete at `lyric/jvm/`, see
`docs/18-jvm-emission.md`) produces Java 21 class files.  For Lambda, the
emitter generates a class `<RootPackage>$LambdaHandler` implementing
`com.amazonaws.services.lambda.runtime.RequestStreamHandler`.

### 12.2 Lambda handler configuration

Set the handler in the Lambda function configuration to:
```
<assembly-name>.<RootPackage>$LambdaHandler::handleRequest
```

For example, if the root package is `MyApp` and the assembly is `MyService`,
set the handler to `MyService.MyApp$LambdaHandler::handleRequest`.

### 12.3 Dependencies

Dependencies are resolved from the `[maven]` table in `lyric.toml`.
When `feature = "jvm"`:

**lyric-lambda:**
- `com.amazonaws:aws-lambda-java-core:1.2.3`
- `com.amazonaws:aws-lambda-java-events:3.11.4`

**lyric-aws-secrets:**
- `software.amazon.awssdk:secretsmanager:2.25.x`
- `software.amazon.awssdk:ssm:2.25.x`

**lyric-aws-xray:**
- `com.amazonaws:aws-xray-recorder-sdk-core:2.15.3`

### 12.4 Feature parity

The JVM kernel implements the same event-detection and dispatch logic as the
.NET kernel.  `Lambda.Direct` function-reference registration is supported.
Streaming writes directly to the Java `OutputStream` passed to `handleRequest`.

---

## 13. X-Ray tracing (`lyric-aws-xray`)

`lyric-aws-xray` provides AWS X-Ray active tracing as a B-mode pub aspect
template.  It is a separate library from `lyric-lambda` so it can also be
used with `lyric-web` services running on Fargate or EC2.

### 13.1 Overview

The Lambda runtime opens a top-level X-Ray segment for every invocation when
active tracing is enabled on the function.  `lyric-aws-xray` wraps individual
Lyric function calls as subsegments of that segment.

### 13.2 Installation and setup

1. Enable active tracing on the Lambda function (console / CDK / SAM).
2. Add `lyric-aws-xray` to `[dependencies]` in `lyric.toml`.
3. Grant the execution role `xray:PutTraceSegments` and
   `xray:PutTelemetryRecords` on `*`.

### 13.3 Tracing aspect

```lyric
import AwsXRay

aspect TraceHandlers from AwsXRay.Tracing {
  matches: name like "handle*"
  config {
    enabled: Bool = true   // disable with env LYRIC_ASPECT_TRACEHANDLERS_ENABLED=false
  }
}
```

The aspect wraps each matched call in a subsegment named after the function's
qualified name (e.g. `"MyApp.Orders.handleCreate"`).  On `Err(_)` the error
message is added as the `"error"` annotation; on `Ok(_)` or non-Result returns
the subsegment closes cleanly.

Compose inside `Lambda.Aspects.EventLogging` to measure timing around the full
subsegment including X-Ray overhead:

```lyric
aspect LogAll from Lambda.Aspects.EventLogging {
  matches: name like "handle*"
}

aspect TraceHandlers from AwsXRay.Tracing {
  matches: name like "handle*"
  inside:  LogAll
}
```

### 13.4 Annotations and metadata

From within a handler body wrapped by the `Tracing` aspect:

```lyric
val seg = AwsXRay.currentSubsegment()
AwsXRay.annotate(seg, "orderId", orderId)   // indexed; searchable in X-Ray filter expressions
AwsXRay.metadata(seg, "payload", rawJson)  // not indexed; visible in trace view
```

### 13.5 Local mode (feature = "local")

All X-Ray calls are silently dropped in local mode; no X-Ray daemon or AWS
credentials are required.  The `AwsXRay.Tracing` aspect is a transparent
pass-through — handlers run unchanged.

---

## 14. Runtime config env vars

```
LYRIC_CONFIG_LAMBDA_RUNTIME_LOCALPORT           — local test server port (default: 9000)
LYRIC_CONFIG_AWSSECRETS_SECRETCACHE_TTLSECONDS  — secret cache TTL in seconds (default: 300)
LYRIC_LOCAL_TIMEOUT_MS                          — remainingTimeMs in synthetic context (default: 30000)
```

All `Web.Server.*` and `Web.Cors.*` env vars apply when an `httpRouter` is attached.

---

## 15. Design notes

### 15.1 Cold start

The custom runtime avoids ASP.NET Core startup cost.  For HTTP workloads the
kernel drives dispatch directly without Kestrel, which reduces cold start
compared to `Amazon.Lambda.AspNetCoreServer`.

For Native AOT builds use `Lambda.Direct` (§10) to register handlers via
function references — DLL reflection is absent in AOT binaries and string-named
handlers would fail at startup.

### 15.2 Warm invocation state

Lambda reuses the same process across warm invocations.  `lyric-db` connection
pools and `Std.Http` clients are safe to initialise at module level and reuse
across invocations.  Avoid capturing mutable state in handler closures.

---

## 16. Open questions

| ID | Status | Question |
|---|---|---|
| Q-lambda-001 | **Resolved** — `Lambda.Direct` shipped (D064) | AOT-compatible handler registration |
| Q-lambda-002 | **Resolved** — `lyric-aws-secrets` library shipped (D063) | |
| Q-lambda-003 | **Resolved** — `lyric-aws-xray` shipped (D064) | AWS X-Ray active tracing as aspect |
| Q-lambda-004 | **Resolved** — `Lambda.Stream` shipped (D064) | Response streaming |
| Q-lambda-005 | **Resolved** — `Lambda.Authorizer` shipped (D063) | |
| Q-lambda-006 | **Resolved** — `KinesisEvent` added to `Lambda.Events` (D063) | |
| Q-lambda-JVM | **Resolved** — JVM kernels shipped for all three libraries (D064) | JVM target support |
