# lyric-lambda

AWS Lambda runtime adapter for [Lyric](https://github.com/nichobbs/lyric-lang). Deploy services built with `lyric-web` to Lambda with zero handler-code changes, plus support for all major event sources (SQS, SNS, S3, EventBridge, DynamoDB, Kinesis) and Lambda authorizers.

> **Status**: @experimental — the `aws`/`local`/`jvm` runtime loop
> (event-source detection, JSON marshalling, `Lambda.Direct` dispatch, and
> the wire-level HTTP transport) is real, pure-Lyric code, no longer an
> unbacked `extern package` declaration, and all three feature variants
> share the identical `Lambda.Dispatch` implementation (`jvm` deploys as a
> `provided.al2`/`provided.al2023` custom runtime — a resolved
> deployment-model decision, see "Known gaps"). `aws:sqs`, `aws:sns`,
> `aws:s3`, `aws:dynamodb`, `aws:kinesis`, EventBridge, the `raw`
> catch-all, and all three authorizer types are fully wired; the
> `Lambda.Kernel.WebBridge` router-token registry is real and proven
> (`Lambda.withRouter`'s `LambdaRouter` token resolves back to its
> `Web.Router`), but routing an API Gateway/ALB event *through* the
> resolved router, and response streaming, are both separate, larger,
> not-yet-implemented features (see "Known gaps" below). See
> `docs/35-lambda-library.md` and the decision log (D062–D064, D099,
> D-progress-882).

## Platform parity

| Feature flag | Runtime | Status |
|---|---|---|
| `aws` | .NET custom runtime: HTTP long-polling against `$AWS_LAMBDA_RUNTIME_API` | Available — all six event sources (`aws:sqs`/`aws:sns`/`aws:s3`/`aws:dynamodb`/`aws:kinesis`/EventBridge), `raw`, and authorizers wired; HTTP/streaming not implemented (see "Known gaps") |
| `local` | Local test server (compatible with `sam local invoke`) | Available — same dispatch logic and gaps as `aws`, different transport |
| `jvm` | JVM custom runtime (`provided.al2`/`provided.al2023`): the SAME `Lambda.Dispatch` HTTP long-polling loop as `aws` | Available — same dispatch logic and gaps as `aws`/`local`; verified in isolation (a standalone `Std.Http`+`Std.HttpServer`+`scope`/`spawn`/`await` spike passes on `--target jvm`) — full project-level `--target jvm` verification is blocked in this environment by an unrelated, pre-existing Maven-resolver gap (see "Known gaps") |

## Packages

| Package | Description |
|---|---|
| `Lambda` | Core: `LambdaApp` builder, `serve()` entry point, `LambdaContext`, the `Lambda.Direct` handler interfaces |
| `Lambda.ApiGw` | API Gateway / ALB event types and response builders |
| `Lambda.Events` | SQS, SNS, S3, EventBridge, DynamoDB, Kinesis event types |
| `Lambda.Authorizer` | REST API TOKEN/REQUEST and HTTP API v2 authorizers |
| `Lambda.Direct` | AOT-safe handler registration via typed interfaces |
| `Lambda.Dispatch` | Event-source detection, JSON marshalling, and the `aws`/`local` transport loops |
| `Lambda.Stream` | Response streaming support via `StreamWriter` — **not implemented** (no working transport) |
| `Lambda.Aspects` | Template aspects: `EventLogging`, `DeadlineGuard` |
| `Lambda.Kernel.Runtime` | Extern boundary (one per feature flag); `aws`/`local` are now thin wrappers around `Lambda.Dispatch` |

## Installation

```toml
[dependencies]
"Lyric.Lambda" = { path = "../lyric-lambda" }
"Lyric.Web" = { path = "../lyric-web" }       # optional, for HTTP handlers

[features]
aws = []    # production Lambda runtime (.NET custom runtime)
local = []  # local test server
jvm = []    # production Lambda runtime (JVM custom runtime, provided.al2/al2023)
```

## Quick start

> **Note:** The self-hosted compiler does not yet implement the `|>` pipe
> operator (tracked in #3520). The examples below use the equivalent nested
> call form; re-express as a left-to-right pipeline once pipe support lands.

### HTTP service (API Gateway / ALB) — dispatch not yet implemented

`Lambda.withRouter` compiles, registers a `Web.Router`, and the resulting
`LambdaRouter` token DOES resolve back to that exact router at runtime
(`Lambda.Kernel.WebBridge`'s registry is real — see
`tests/lambda_webbridge_tests.l`). What's still missing is routing a live
API Gateway/ALB event *through* the resolved router (method/path/header/
body extraction, match-and-dispatch, `ApiGwResponse` encoding, CORS) — a
separate, larger feature; `dispatchInvocation` still fails closed with
`LambdaError.InternalError` for these events, now naming this specific
gap. Use event-driven handlers (below) until that lands.

### Event-driven handlers (SQS, SNS, etc.)

Register handlers with `Lambda.Direct` — a small (usually zero-field)
record implementing the matching handler interface, not a bare function or
closure. Each factory's parameter type is the interface itself (e.g.
`SqsHandler`), so a bare function can't be passed there at all — Lyric
interfaces are nominal (`impl`-only), not structurally satisfied by a
function value. The interface shape exists because invoking a closure
across the two or more packages this registration path spans (consumer
handler -> `Lambda.Direct`'s factory -> the kernel's dispatch) remains
unreliable on the self-hosted MSIL backend (#5363, still open on both
targets): `docs/03-decision-log.md`'s "Decision 4" entry. The other bug
that originally motivated this design, #5362 (a bare same-package named
function used directly as a function-typed value crashing at runtime), is
now fixed on `--target dotnet`; it remains broken on `--target jvm`.

```lyric
import Lambda
import Lambda.Direct
import Lambda.Events
import Std.Core

record HandleSqsMessage {}

impl Lambda.SqsHandler for HandleSqsMessage {
  func handle(event: in SqsEvent, ctx: in Lambda.LambdaContext): Result[Unit, Lambda.LambdaError] {
    for record in event.records {
      // Process SQS message
      val body = record.body
      // ... do work ...
    }
    return Ok(value = ())
  }
}

func main(): Int {
  Lambda.serve(
    Lambda.withDirect(Lambda.newApp(), Lambda.Direct.sqsHandler(HandleSqsMessage()))
  )
  return 0
}
```

All six event sources (`aws:sqs`, `aws:sns`, `aws:s3`, `aws:dynamodb`,
`aws:kinesis`, EventBridge), the `raw` catch-all, and the three authorizer
types (`TOKEN`/`REQUEST`/HTTP API v2) dispatch today via `Lambda.Direct`.
The legacy string-based `onSqs`/`onSns`/etc. registration (resolved "via
DLL reflection") was never implemented and cannot be: `lyric-health`'s
identical design was rejected outright in D099. Prefer `Lambda.Direct`.

### Multiple event sources

```lyric
import Lambda
import Lambda.Direct
import Lambda.Events
import Lambda.Authorizer

record HandleSqsMessage {}
impl Lambda.SqsHandler for HandleSqsMessage {
  func handle(event: in SqsEvent, ctx: in Lambda.LambdaContext): Result[Unit, Lambda.LambdaError] {
    return Ok(value = ())
  }
}

record VerifyJwt {}
impl Lambda.TokenAuthorizerHandler for VerifyJwt {
  func handle(event: in TokenAuthorizerEvent, ctx: in Lambda.LambdaContext): Result[AuthorizerResponse, Lambda.LambdaError] {
    // ... validate event.authorizationToken ...
    return Ok(value = Lambda.Authorizer.allowAll("user-1", event.methodArn))
  }
}

func main(): Int {
  Lambda.serve(
    Lambda.withDirect(
      Lambda.withDirect(Lambda.newApp(), Lambda.Direct.sqsHandler(HandleSqsMessage())),
      Lambda.Direct.tokenAuthorizerHandler(VerifyJwt())
    )
  )
  return 0
}
```

## LambdaApp builder

The fluent builder API configures all aspects of the Lambda function. Each
builder below takes the `LambdaApp` as its first argument and returns an
updated `LambdaApp`; the `|>` pipe form is shown for readability, but the
self-hosted compiler does not yet implement `|>` (#3520) — chain builders
with nested calls or intermediate `var` reassignment, as in the Quick start
examples above.

### HTTP routing

```lyric
|> Lambda.withRouter(router)          // Attach a Web.Router for HTTP events
|> Lambda.withStreamingHandler(name)  // Register a streaming handler (Function URL)
```

### Event handlers

**`onSqs`/`onSns`/etc. (string-based, by qualified function name) do not
dispatch.** They were meant to be resolved "via DLL reflection" at
startup; no such resolver was ever implemented and D099
(docs/03-decision-log.md) rejects that design outright for this codebase.
Registering one is harmless (the builder methods below just record a
name), but the runtime loop cannot invoke it — a matching event with only
a string-based registration and no `Lambda.Direct` handler fails closed
with `LambdaError.InternalError`. **Use `Lambda.Direct` (below) instead.**

| Builder | Event source | Handler signature |
|---|---|---|
| `onSqs` | AWS SQS | `(SqsEvent, LambdaContext) -> Result[Unit \| SqsBatchResponse, LambdaError]` |
| `onSns` | AWS SNS | `(SnsEvent, LambdaContext) -> Result[Unit, LambdaError]` |
| `onS3` | AWS S3 | `(S3Event, LambdaContext) -> Result[Unit, LambdaError]` |
| `onEventBridge` | AWS EventBridge | `(EventBridgeEvent, LambdaContext) -> Result[Unit, LambdaError]` |
| `onDynamoDb` | DynamoDB Streams | `(DynamoDbEvent, LambdaContext) -> Result[Unit, LambdaError]` |
| `onKinesis` | Amazon Kinesis | `(KinesisEvent, LambdaContext) -> Result[Unit, LambdaError]` |
| `onRaw` | Raw event (any JSON) | `(String, LambdaContext) -> Result[Unit, LambdaError]` |

### Authorizers

```lyric
|> Lambda.onTokenAuthorizer(name)     // REST API TOKEN authorizer
|> Lambda.onRequestAuthorizer(name)   // REST API REQUEST authorizer
|> Lambda.onHttpAuthorizer(name)      // HTTP API v2 authorizer
```

Same caveat as event handlers above — prefer `Lambda.Direct.tokenAuthorizerHandler`/etc.

### AOT-safe handler registration (the only dispatch path that actually works)

```lyric
|> Lambda.withDirect(Lambda.Direct.sqsHandler(HandleQueue()))
|> Lambda.withDirect(Lambda.Direct.tokenAuthorizerHandler(VerifyJwt()))
```

Each factory takes an instance of the matching interface (`Lambda.SqsHandler`,
`Lambda.TokenAuthorizerHandler`, ...) implemented by a small record — not a
bare function or closure (the parameter type is the interface itself, so a
bare function is a compile-time type mismatch, not merely discouraged).
Closures invoked across the three packages this registration path
necessarily spans (consumer handler -> `Lambda.Direct`'s factory -> the
kernel's dispatch) are unreliable on the current self-hosted MSIL backend
(#5363, still open on both targets) — see `docs/03-decision-log.md`'s
"Decision 4" entry, which fixed the identical problem for
`Web.Handler`/`Web.Middleware`. The entry's other motivating bug, #5362 (a
bare same-package named function crashing when used directly as a
function-typed value), is now fixed on `--target dotnet` and remains open
on `--target jvm`; it doesn't change the interface requirement here since
#5363 alone still blocks a function-typed alternative. This is also
required (not just AOT-recommended) for anything to dispatch at all today.

## Event types

### SQS (`Lambda.Events.SqsEvent`)

```lyric
record SqsEvent {
  records: slice[SqsRecord]
}

record SqsRecord {
  messageId: String
  receiptHandle: String
  body: String
  attributes: Map[String, String]
  messageAttributes: Map[String, SqsMessageAttribute]
  md5OfBody: String
  eventSource: String
  eventSourceArn: String
  awsRegion: String
}
```

### SNS (`Lambda.Events.SnsEvent`)

```lyric
record SnsRecord {
  sns: SnsMessage
}

record SnsMessage {
  type: String       // "Notification", "SubscriptionConfirmation", etc.
  messageId: String
  topicArn: String
  subject: Option[String]
  message: String
  timestamp: String
  signatureVersion: String
  signature: String
  signingCertUrl: String
  unsubscribeUrl: Option[String]
}
```

### API Gateway v1 / v2 / ALB

API Gateway events are automatically dispatched to the configured `Web.Router`. The response is serialized to `ApiGwResponse` with the appropriate format for each API type.

### S3, EventBridge, DynamoDB, Kinesis

See the event type definitions in `Lambda.Events` for complete field references.

## SQS partial-batch failure

Return `SqsBatchResponse` to enable per-message failure reporting:

```lyric
func handleSqsBatch(event: SqsEvent, ctx: Lambda.LambdaContext): Result[SqsBatchResponse, Lambda.LambdaError] {
  var failures = []

  for record in event.records {
    match processMessage(record) {
      case Ok(_) -> {}
      case Err(e) -> {
        failures = failures + [SqsBatchResponse.FailureRecord(id = record.messageId)]
      }
    }
  }

  Ok(SqsBatchResponse(batchItemFailures = failures))
}
```

Enable batch reporting in the Lambda event source mapping configuration:
```
FunctionResponseTypes = ["ReportBatchItemFailures"]
```

## Authorizers

### REST API TOKEN authorizer

```lyric
import Lambda.Authorizer

func verifyToken(
  event: Lambda.Authorizer.TokenAuthorizerEvent,
  ctx: Lambda.LambdaContext
): Result[Lambda.Authorizer.AuthorizerResponse, Lambda.LambdaError] {
  val token = event.authorizationToken
  match validateJwt(token) {
    case Ok(claims) -> {
      Ok(
        Lambda.Authorizer.allowAll(claims.sub, event.methodArn)
          |> Lambda.Authorizer.withContext(Map.of([
            ("userId", claims.sub),
            ("role", claims.role)
          ]))
      )
    }
    case Err(_) -> {
      Ok(Lambda.Authorizer.deny("anonymous", event.methodArn))
    }
  }
}
```

### HTTP API v2 authorizer

```lyric
func verifyHttpAuthorizer(
  event: Lambda.Authorizer.HttpAuthorizerEvent,
  ctx: Lambda.LambdaContext
): Result[Lambda.Authorizer.HttpAuthorizerResponse, Lambda.LambdaError] {
  if validateToken(event.identitySource) {
    Ok(Lambda.Authorizer.authorizedWithContext(Map.of([
      ("userId", extractUserId(event.identitySource))
    ])))
  } else {
    Ok(Lambda.Authorizer.denied())
  }
}
```

## Response streaming (Function URL) — not implemented

`Lambda.Stream.StreamWriter` has no working kernel: nothing constructs an
instance or wires it to a real transport, and every function in
`Lambda.Stream` panics with a clear "not implemented" message if called.
The type signatures below are the intended future shape, kept so
downstream code sketches compile against the interface once the
transport exists — see "Known gaps".

Use `Lambda.Stream.StreamWriter` to stream large responses:

```lyric
import Lambda
import Lambda.Stream

func streamLargeFile(
  event: String,
  ctx: Lambda.LambdaContext,
  writer: Lambda.Stream.StreamWriter
): Result[Unit, Lambda.LambdaError] {
  // Stream response in chunks
  val chunk1 = "chunk of data..."
  Lambda.Stream.write(writer, chunk1)?
  
  val chunk2 = "more data..."
  Lambda.Stream.write(writer, chunk2)?
  
  Lambda.Stream.close(writer)
  Ok(Unit)
}
```

Register with:
```lyric
Lambda.serve(
  Lambda.newApp()
    |> Lambda.withStreamingHandler("MyApp.Stream.streamLargeFile")
)
```

## LambdaContext

All handlers receive context about the invocation:

```lyric
record LambdaContext {
  functionName: String           // "my-function"
  functionVersion: String        // "$LATEST" or version number
  invokedFunctionArn: String     // "arn:aws:lambda:..."
  memoryLimitInMb: Int           // allocated memory
  requestId: String              // unique request ID
  remainingTimeMs: Long          // milliseconds until timeout
}
```

Use `remainingTimeMs` to implement deadline guards with the `DeadlineGuard` aspect.

## Aspect templates

### `Lambda.Aspects.EventLogging`

Logs handler invocation and outcome:

```lyric
import Lambda.Aspects

aspect LogHandlers from Lambda.Aspects.EventLogging {
  matches: name like "handle*"
  config {
    level: LogLevel = LogLevel.Info
  }
}
```

| Config field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `level` | `LogLevel` | `Info` | Logging level |

### `Lambda.Aspects.DeadlineGuard`

Fails if remaining time is below threshold:

```lyric
import Lambda.Aspects

aspect GuardTimeout from Lambda.Aspects.DeadlineGuard {
  matches: name like "handle*"
  config {
    thresholdMs: Long = 500
  }
}
```

| Config field | Type | Default | Description |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `thresholdMs` | `Long` | `500` | Time remaining threshold (ms) |

## Local development

### With feature = "local"

Build with `local` feature to run a real (not mocked) HTTP test server —
`Lambda.Dispatch.runLocalServer` binds `localhost:{port}` via
`Std.HttpServer` and dispatches every POST body through the same
`dispatchInvocation` logic the `aws` feature uses:

```bash
lyric build --manifest lyric.toml --features local
./bin/lambda
```

Server listens on `localhost:9000` (override via
`LYRIC_CONFIG_LAMBDA_RUNTIME_LOCALPORT`).

Compatible with `sam local invoke` / `aws lambda invoke --endpoint-url`:

```bash
curl -X POST http://localhost:9000/2015-03-31/functions/function/invocations -d @event.json
sam local invoke MyFunction --event event.json
```

A handler failure responds HTTP 200 with the AWS error JSON shape
(`{"errorMessage","errorType"}`) and an `X-Amz-Function-Error: Unhandled`
header, matching the real Invoke API's contract — the invoke always
succeeds at the transport level; only the body/header say whether the
handler itself failed.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `LYRIC_CONFIG_LAMBDA_RUNTIME_LOCALPORT` | `9000` | Port for local test server (`local` feature) |
| `LYRIC_LOCAL_TIMEOUT_MS` | `30000` | Simulated remaining-time budget for local invocations |
| `AWS_LAMBDA_RUNTIME_API` | — | `host:port` of the Runtime API to poll (`aws` feature; set by the real Lambda execution environment) |
| `AWS_LAMBDA_FUNCTION_NAME` / `_VERSION` / `_MEMORY_SIZE` | — | Surfaced verbatim on `LambdaContext` (`aws` feature; set by the real Lambda execution environment) |
| `AWS_LAMBDA_LOG_GROUP_NAME` / `_LOG_STREAM_NAME` | — | Surfaced verbatim on `LambdaContext` (`aws` feature; set by the real Lambda execution environment) |

### No AWS credentials required

Local mode skips all AWS API calls. Set env vars for any config you need locally.

## Known gaps

Precise status of everything that is *not* fully implemented, so nothing
here is a silent no-op — each one fails loudly (`LambdaError.InternalError`
or a `panic` with an explanatory message) rather than pretending to work:

| Gap | Where it fails | What's needed |
|---|---|---|
| API Gateway v1/v2/ALB dispatch (`Lambda.withRouter`) | `dispatchInvocation` returns `InternalError` naming this gap specifically | Routing a live event through the now-resolvable `Web.Router` (method/path/header/body extraction, match-and-dispatch, `ApiGwResponse` encoding, CORS) — the router-token registry itself (`Lambda.Kernel.WebBridge.createRouterToken`/`lookupRouter`) is real and proven (`tests/lambda_webbridge_tests.l`) |
| Response streaming (`Lambda.Stream`, `Lambda.withStreamingHandler`, `Lambda.Direct.streamingHandler`) | Every `Lambda.Stream` function panics; `streamingHandler` panics at registration time | A real streaming transport design (Function URL `RESPONSE_STREAM` uses a different invoke path than the GET-next/POST-response loop this library implements) |
| `web` feature not target-gated | Compiles regardless of `--target`; `ConditionalWeakTable` (its extern boundary) is .NET-only | Target-gating, or a JVM-side registry (a plain `Map[LambdaRouter, Web.Router]` needs no weak table on that target) once a real JVM `feature = "web"` consumer exists |
| String-based `on*`/`onTokenAuthorizer`/etc. registration | Registers successfully; dispatch fails closed if no `Lambda.Direct` handler also covers the same source | None planned — `Lambda.Direct` is the sanctioned replacement (D099) |
| Full project-level `--target jvm` verification | Blocked in sandboxed CI-like environments without a `lyric-resolver.jar` (Maven resolution unavailable to fetch `lyric-web`'s `io.undertow:undertow-core`, which `Lambda`'s unconditional `import Web` pulls in transitively on JVM) | A `lyric-resolver.jar` (`make maven-resolver`) with network access to Maven Central; the JVM kernel logic itself is verified in isolation (a standalone `Std.Http`+`Std.HttpServer`+`scope`/`spawn`/`await` spike passes on `--target jvm`) |

## Package layout

```
lyric-lambda/
  lyric.toml                      package manifest
  README.md                       this file
  src/
    lambda.l                      Lambda  (core types, LambdaApp, serve, Lambda.Direct's handler interfaces)
    apigw.l                       Lambda.ApiGw  (API Gateway / ALB)
    events.l                      Lambda.Events  (SQS, SNS, S3, ...)
    authorizer.l                  Lambda.Authorizer  (authorizer types)
    direct.l                      Lambda.Direct  (AOT handler registration)
    dispatch.l                    Lambda.Dispatch  (event detection, JSON marshalling, aws/local transport loops)
    stream.l                      Lambda.Stream  (response streaming — not implemented)
    lambda_aspects.l              Lambda.Aspects  (EventLogging, DeadlineGuard)
    _kernel/
      lambda_kernel_aws.l         Lambda.Kernel.Runtime @cfg(feature="aws")     — thin wrapper over Lambda.Dispatch
      lambda_kernel_local.l       Lambda.Kernel.Runtime @cfg(feature="local")   — thin wrapper over Lambda.Dispatch
      lambda_kernel_jvm.l         Lambda.Kernel.Runtime @cfg(feature="jvm")     — thin wrapper over the SAME Lambda.Dispatch loop as aws (custom runtime)
      lambda_kernel_web.l         Lambda.Kernel.WebBridge @cfg(feature="web")  — real ConditionalWeakTable<LambdaRouter, Web.Router> registry
  tests/
    *_tests.l                          registered in [project.tests]
    lambda_webbridge_tests.l           NOT registered (needs --features web; see file header)
    lambda_runtime_loop_tests.l        NOT registered (needs --target jvm --features jvm; see file header)
```

## See also

- `lyric-web` — HTTP routing framework (for `withRouter`)
- `lyric-aws-secrets` — AWS Secrets Manager / Parameter Store integration
- `lyric-aws-xray` — AWS X-Ray active tracing
- `docs/35-lambda-library.md` — complete design specification
- `docs/03-decision-log.md` D062, D063, D064, D099, and "Decision 4 — Handler/Middleware are interfaces, not closures" — design decisions
