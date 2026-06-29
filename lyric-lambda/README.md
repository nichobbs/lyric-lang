# lyric-lambda

AWS Lambda runtime adapter for [Lyric](https://github.com/nichobbs/lyric-lang). Deploy services built with `lyric-web` to Lambda with zero handler-code changes, plus support for all major event sources (SQS, SNS, S3, EventBridge, DynamoDB, Kinesis) and Lambda authorizers.

> **Status**: @experimental — the API Gateway v1/v2/ALB bridges compile and unit tests cover the request-shape adapters, but the live AWS Lambda runtime has not been exercised in CI. `.NET` and JVM targets are available via feature flags.

## Platform parity

| Feature flag | Runtime | Status |
|---|---|---|
| `aws` | .NET custom runtime via `Amazon.Lambda.RuntimeSupport` | Available |
| `local` | Local test server (compatible with `sam local invoke`) | Available |
| `jvm` | JVM managed runtime (`RequestStreamHandler`) | Available |

## Packages

| Package | Description |
|---|---|
| `Lambda` | Core: `LambdaApp` builder, `serve()` entry point, `LambdaContext` |
| `Lambda.ApiGw` | API Gateway / ALB event types and response builders |
| `Lambda.Events` | SQS, SNS, S3, EventBridge, DynamoDB, Kinesis event types |
| `Lambda.Authorizer` | REST API TOKEN/REQUEST and HTTP API v2 authorizers |
| `Lambda.Direct` | AOT-safe function-reference handler registration |
| `Lambda.Stream` | Response streaming support via `StreamWriter` |
| `Lambda.Aspects` | Template aspects: `EventLogging`, `DeadlineGuard` |
| `Lambda.Kernel.Runtime` | Extern boundary (one per feature flag) |

## Installation

```toml
[dependencies]
"Lyric.Lambda" = { path = "../lyric-lambda" }
"Lyric.Web" = { path = "../lyric-web" }       # optional, for HTTP handlers

[features]
aws = []    # production Lambda runtime
local = []  # local test server
jvm = []    # JVM managed runtime
```

## Quick start

### HTTP service (API Gateway / ALB)

```lyric
import Lambda
import Web
import Std.Core

func main(): Int {
  var router = Web.create()
  router = Web.addGet(router, "/users/{id}", "MyApp.Users.getUser")
  router = Web.addPost(router, "/users", "MyApp.Users.createUser")

  Lambda.serve(
    Lambda.newApp()
      |> Lambda.withRouter(router)
  )
  
  return 0
}
```

### Event-driven handlers (SQS, SNS, etc.)

```lyric
import Lambda
import Lambda.Events
import Std.Core

func handleSqsMessage(event: SqsEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError] {
  for record in event.records {
    // Process SQS message
    val body = record.body
    // ... do work ...
  }
  Ok(Unit)
}

func main(): Int {
  Lambda.serve(
    Lambda.newApp()
      |> Lambda.onSqs("MyApp.Queue.handleSqsMessage")
  )
  return 0
}
```

### Multiple event sources

```lyric
import Lambda
import Lambda.Events
import Lambda.Authorizer
import Web

func main(): Int {
  var router = Web.create()
  router = Web.addGet(router, "/health", "MyApp.Handlers.getHealth")

  Lambda.serve(
    Lambda.newApp()
      |> Lambda.withRouter(router)                          // API Gateway HTTP
      |> Lambda.onSqs("MyApp.Queue.handleSqsMessage")       // SQS batches
      |> Lambda.onTokenAuthorizer("MyApp.Auth.verifyJwt")   // REST API authorizer
  )
  
  return 0
}
```

## LambdaApp builder

The fluent builder API configures all aspects of the Lambda function:

### HTTP routing

```lyric
|> Lambda.withRouter(router)          // Attach a Web.Router for HTTP events
|> Lambda.withStreamingHandler(name)  // Register a streaming handler (Function URL)
```

### Event handlers

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

### AOT-safe handler registration

```lyric
|> Lambda.withDirect(Lambda.Direct.sqsHandler(MyApp.Queue.handle))
|> Lambda.withDirect(Lambda.Direct.tokenAuthorizerHandler(MyApp.Auth.verify))
```

Use `Lambda.Direct` factory functions when compiling with `PublishAot=true`.

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

## Response streaming (Function URL)

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

Build with `local` feature to run a test HTTP server:

```bash
lyric build --manifest lyric.toml --feature local
./bin/lambda
```

Server listens on `localhost:9000` (override via `LYRIC_LAMBDA_LOCALPORT`).

Compatible with `sam local invoke`:

```bash
sam local invoke MyFunction --event event.json
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `LYRIC_LAMBDA_LOCALPORT` | `9000` | Port for local test server |
| `LYRIC_LOCAL_TIMEOUT_MS` | `30000` | Simulated timeout for local invocations |

### No AWS credentials required

Local mode skips all AWS API calls. Set env vars for any config you need locally.

## Package layout

```
lyric-lambda/
  lyric.toml                      package manifest
  README.md                       this file
  src/
    lambda.l                      Lambda  (core types, LambdaApp, serve)
    apigw.l                       Lambda.ApiGw  (API Gateway / ALB)
    events.l                      Lambda.Events  (SQS, SNS, S3, ...)
    authorizer.l                  Lambda.Authorizer  (authorizer types)
    direct.l                      Lambda.Direct  (AOT handler registration)
    stream.l                      Lambda.Stream  (response streaming)
    lambda_aspects.l              Lambda.Aspects  (EventLogging, DeadlineGuard)
    _kernel/
      lambda_kernel_aws.l         Lambda.Kernel.Runtime @cfg(feature="aws")
      lambda_kernel_local.l       Lambda.Kernel.Runtime @cfg(feature="local")
      lambda_kernel_jvm.l         Lambda.Kernel.Runtime @cfg(feature="jvm")
  tests/
    *_tests.l                     test modules
```

## See also

- `lyric-web` — HTTP routing framework (for `withRouter`)
- `lyric-aws-secrets` — AWS Secrets Manager / Parameter Store integration
- `lyric-aws-xray` — AWS X-Ray active tracing
- `docs/35-lambda-library.md` — complete design specification
- `docs/03-decision-log.md` D062, D063, D064 — design decisions
