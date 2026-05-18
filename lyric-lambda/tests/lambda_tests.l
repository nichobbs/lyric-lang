// tests/lambda_tests.l — tests for the pure-Lyric surface of the Lambda package.
//
// Covers LambdaError construction and errorMessage formatting, LambdaApp builder
// (newApp / onSqs / onSns / onS3 / onEventBridge / onDynamoDb / onKinesis / onRaw /
// withStreamingHandler / onTokenAuthorizer / onRequestAuthorizer / onHttpAuthorizer),
// event record construction (SqsEvent, SnsEvent, S3Event, EventBridgeEvent,
// DynamoDbEvent, KinesisEvent), and Lambda.Authorizer pure helpers
// (allow, allowAll, deny, withContext, withUsageKey, authorized,
// authorizedWithContext, denied).
// serve() and the kernel runtime loop require the Lambda Runtime API and
// are not exercised here.

@test_module
package Lambda.LambdaTests

import Std.Core
import Std.Testing
import Std.Collections
import Lambda
import Lambda.Events
import Lambda.Authorizer

// ─── LambdaError ─────────────────────────────────────────────────────────────

test "LambdaError.HandlerError: carries message and errorType" {
  val e = LambdaError.HandlerError(message = "boom", errorType = "ValidationError")
  match e {
    case LambdaError.HandlerError(message = m, errorType = t) -> {
      assertEqual(m, "boom",            "message field")
      assertEqual(t, "ValidationError", "errorType field")
    }
    case _ -> assertTrue(false, "expected HandlerError")
  }
}

test "LambdaError.ParseError: carries message" {
  val e = LambdaError.ParseError(message = "unexpected token")
  match e {
    case LambdaError.ParseError(message = m) -> assertEqual(m, "unexpected token", "message field")
    case _                                   -> assertTrue(false, "expected ParseError")
  }
}

test "LambdaError.TimeoutError: carries remainingMs" {
  val e = LambdaError.TimeoutError(remainingMs = 150L)
  match e {
    case LambdaError.TimeoutError(remainingMs = ms) -> assertTrue(ms == 150L, "remainingMs field")
    case _                                          -> assertTrue(false, "expected TimeoutError")
  }
}

test "LambdaError.InternalError: carries message" {
  val e = LambdaError.InternalError(message = "handler not found")
  match e {
    case LambdaError.InternalError(message = m) -> assertEqual(m, "handler not found", "message field")
    case _                                      -> assertTrue(false, "expected InternalError")
  }
}

// ─── errorMessage ─────────────────────────────────────────────────────────────

test "errorMessage: HandlerError includes errorType and message" {
  val e   = LambdaError.HandlerError(message = "bad input", errorType = "ValidationError")
  val msg = Lambda.errorMessage(e)
  assertTrue(msg.contains("ValidationError"), "message includes errorType")
  assertTrue(msg.contains("bad input"),       "message includes handler message")
}

test "errorMessage: ParseError includes prefix and message" {
  val e   = LambdaError.ParseError(message = "invalid JSON")
  val msg = Lambda.errorMessage(e)
  assertTrue(msg.contains("ParseError"),    "message includes ParseError prefix")
  assertTrue(msg.contains("invalid JSON"),  "message includes inner message")
}

test "errorMessage: TimeoutError includes remaining ms" {
  val e   = LambdaError.TimeoutError(remainingMs = 42L)
  val msg = Lambda.errorMessage(e)
  assertTrue(msg.contains("42"),          "message includes remaining ms")
  assertTrue(msg.contains("TimeoutError"), "message includes TimeoutError prefix")
}

test "errorMessage: InternalError includes message" {
  val e   = LambdaError.InternalError(message = "DLL not found")
  val msg = Lambda.errorMessage(e)
  assertTrue(msg.contains("InternalError"), "message includes InternalError prefix")
  assertTrue(msg.contains("DLL not found"), "message includes inner message")
}

// ─── LambdaApp builder ───────────────────────────────────────────────────────

test "newApp: creates empty LambdaApp" {
  val app = Lambda.newApp()
  assertTrue(app.eventHandlers.length      == 0, "no event handlers initially")
  assertTrue(app.authorizerHandlers.length == 0, "no authorizer handlers initially")
  assertTrue(app.directHandlers.length     == 0, "no direct handlers initially")
  match app.httpRouter {
    case None    -> ()
    case Some(_) -> assertTrue(false, "httpRouter must be None initially")
  }
}

test "onSqs: registers SQS handler" {
  val app = Lambda.newApp() |> Lambda.onSqs("MyApp.Queue.handle")
  assertEqualInt(app.eventHandlers.length, 1, "one event handler registered")
  assertEqual(app.eventHandlers[0].eventSource, "aws:sqs",           "event source")
  assertEqual(app.eventHandlers[0].handlerName, "MyApp.Queue.handle", "handler name")
}

test "onSns: registers SNS handler" {
  val app = Lambda.newApp() |> Lambda.onSns("MyApp.Notify.handle")
  assertEqualInt(app.eventHandlers.length, 1, "one handler")
  assertEqual(app.eventHandlers[0].eventSource, "aws:sns", "event source")
}

test "onS3: registers S3 handler" {
  val app = Lambda.newApp() |> Lambda.onS3("MyApp.Storage.handle")
  assertEqual(app.eventHandlers[0].eventSource, "aws:s3", "event source")
}

test "onEventBridge: registers EventBridge handler" {
  val app = Lambda.newApp() |> Lambda.onEventBridge("MyApp.Events.handle")
  assertEqual(app.eventHandlers[0].eventSource, "aws.events", "event source")
}

test "onDynamoDb: registers DynamoDB handler" {
  val app = Lambda.newApp() |> Lambda.onDynamoDb("MyApp.Dynamo.handle")
  assertEqual(app.eventHandlers[0].eventSource, "aws:dynamodb", "event source")
}

test "onKinesis: registers Kinesis handler" {
  val app = Lambda.newApp() |> Lambda.onKinesis("MyApp.Stream.handle")
  assertEqual(app.eventHandlers[0].eventSource, "aws:kinesis", "event source")
}

test "onRaw: registers catch-all handler" {
  val app = Lambda.newApp() |> Lambda.onRaw("MyApp.Raw.handle")
  assertEqual(app.eventHandlers[0].eventSource, "raw", "event source is raw")
}

test "chained event handlers: each produces a unique entry" {
  val app = Lambda.newApp()
    |> Lambda.onSqs("MyApp.Queue.handle")
    |> Lambda.onS3("MyApp.Storage.handle")
    |> Lambda.onEventBridge("MyApp.Events.handle")
  assertEqualInt(app.eventHandlers.length, 3, "three handlers registered")
}

test "withStreamingHandler: sets streamingHandler name" {
  val app = Lambda.newApp() |> Lambda.withStreamingHandler("MyApp.Stream.handle")
  match app.streamingHandler {
    case None    -> assertTrue(false, "streamingHandler must be Some")
    case Some(n) -> assertEqual(n, "MyApp.Stream.handle", "streaming handler name")
  }
}

test "onTokenAuthorizer: registers token authorizer" {
  val app = Lambda.newApp() |> Lambda.onTokenAuthorizer("MyApp.Auth.token")
  assertEqualInt(app.authorizerHandlers.length, 1, "one authorizer registered")
  assertEqual(app.authorizerHandlers[0].authorizerType, "token",         "authorizer type")
  assertEqual(app.authorizerHandlers[0].handlerName,    "MyApp.Auth.token", "handler name")
}

test "onRequestAuthorizer: registers request authorizer" {
  val app = Lambda.newApp() |> Lambda.onRequestAuthorizer("MyApp.Auth.request")
  assertEqual(app.authorizerHandlers[0].authorizerType, "request", "authorizer type")
}

test "onHttpAuthorizer: registers HTTP API authorizer" {
  val app = Lambda.newApp() |> Lambda.onHttpAuthorizer("MyApp.Auth.http")
  assertEqual(app.authorizerHandlers[0].authorizerType, "http", "authorizer type")
}

// ─── Lambda.Events record construction ───────────────────────────────────────

test "SqsEvent: fields are accessible" {
  val rec = SqsRecord(
    messageId         = "msg-1",
    receiptHandle     = "rh-1",
    body              = "{}",
    attributes        = Map.empty(),
    messageAttributes = Map.empty(),
    md5OfBody         = "abc123",
    eventSource       = "aws:sqs",
    eventSourceArn    = "arn:aws:sqs:us-east-1:123:my-queue",
    awsRegion         = "us-east-1")
  val evt = SqsEvent(records = [rec])
  assertEqualInt(evt.records.length, 1, "one record")
  assertEqual(evt.records[0].messageId,   "msg-1", "messageId field")
  assertEqual(evt.records[0].eventSource, "aws:sqs", "eventSource field")
}

test "SqsBatchResponse: batchItemFailures are accessible" {
  val fail = SqsBatchItemFailure(itemIdentifier = "msg-bad")
  val resp = SqsBatchResponse(batchItemFailures = [fail])
  assertEqualInt(resp.batchItemFailures.length, 1, "one failure")
  assertEqual(resp.batchItemFailures[0].itemIdentifier, "msg-bad", "itemIdentifier field")
}

test "EventBridgeEvent: fields are accessible" {
  val evt = EventBridgeEvent(
    version    = "0",
    id         = "evt-uuid",
    source     = "my.service",
    account    = "123456789012",
    time       = "2024-01-01T00:00:00Z",
    region     = "us-east-1",
    resources  = ["arn:aws:events:us-east-1:123::rule/my-rule"],
    detailType = "OrderPlaced",
    detail     = "{\"orderId\":\"o-1\"}")
  assertEqual(evt.source,     "my.service",   "source field")
  assertEqual(evt.detailType, "OrderPlaced",   "detailType field")
  assertEqual(evt.version,    "0",             "version field")
}

test "KinesisStreamRecord: fields are accessible" {
  val kRec = KinesisRecord(
    kinesisSchemaVersion        = "1.0",
    partitionKey                = "pk-1",
    sequenceNumber              = "seq-1",
    data                        = "SGVsbG8=",
    approximateArrivalTimestamp = 1700000000.0)
  val rec = KinesisStreamRecord(
    kinesis           = kRec,
    eventSource       = "aws:kinesis",
    eventVersion      = "1.0",
    eventId           = "eid-1",
    eventName         = "aws:kinesis:record",
    invokeIdentityArn = "arn:aws:iam::123:role/my-role",
    awsRegion         = "us-east-1",
    eventSourceArn    = "arn:aws:kinesis:us-east-1:123:stream/my-stream")
  val evt = KinesisEvent(records = [rec])
  assertEqualInt(evt.records.length, 1, "one record")
  assertEqual(evt.records[0].kinesis.partitionKey, "pk-1", "partitionKey")
  assertEqual(evt.records[0].eventSource, "aws:kinesis", "eventSource")
}

// ─── Lambda.Authorizer pure helpers ──────────────────────────────────────────

test "IamEffect.Allow: can be matched" {
  val eff = IamEffect.Allow
  match eff {
    case IamEffect.Allow -> ()
    case _               -> assertTrue(false, "expected Allow")
  }
}

test "IamEffect.Deny: can be matched" {
  val eff = IamEffect.Deny
  match eff {
    case IamEffect.Deny -> ()
    case _              -> assertTrue(false, "expected Deny")
  }
}

test "allow: returns AuthorizerResponse with Allow effect" {
  val arn  = "arn:aws:execute-api:us-east-1:123:abc/prod/GET/users"
  val resp = Lambda.Authorizer.allow("user-42", arn)
  assertEqual(resp.principalId, "user-42", "principalId")
  assertEqualInt(resp.policyDocument.statement.length, 1, "one statement")
  match resp.policyDocument.statement[0].effect {
    case IamEffect.Allow -> ()
    case _               -> assertTrue(false, "effect must be Allow")
  }
  assertEqual(resp.policyDocument.statement[0].resource[0], arn, "resource ARN")
}

test "deny: returns AuthorizerResponse with Deny effect" {
  val arn  = "arn:aws:execute-api:us-east-1:123:abc/prod/DELETE/admin"
  val resp = Lambda.Authorizer.deny("anon", arn)
  match resp.policyDocument.statement[0].effect {
    case IamEffect.Deny -> ()
    case _              -> assertTrue(false, "effect must be Deny")
  }
}

test "allowAll: resource uses wildcard suffix" {
  val methodArn = "arn:aws:execute-api:us-east-1:123:abc123/prod/GET/users"
  val resp      = Lambda.Authorizer.allowAll("user-42", methodArn)
  val resource  = resp.policyDocument.statement[0].resource[0]
  assertTrue(resource.contains("/*"), "allowAll wildcard resource ends with /*")
  assertTrue(resource.contains("abc123/prod"), "allowAll preserves api/stage prefix")
}

test "withContext: attaches context map to response" {
  val arn  = "arn:aws:execute-api:us-east-1:123:abc/prod/GET/me"
  val base = Lambda.Authorizer.allow("u-1", arn)
  val ctx  = Map.empty[String, String]().set("userId", "u-1").set("role", "admin")
  val resp = Lambda.Authorizer.withContext(base, ctx)
  match resp.context.get("userId") {
    case Some(v) -> assertEqual(v, "u-1",   "userId in context")
    case None    -> assertTrue(false, "userId must be in context")
  }
  match resp.context.get("role") {
    case Some(v) -> assertEqual(v, "admin", "role in context")
    case None    -> assertTrue(false, "role must be in context")
  }
}

test "withUsageKey: sets usageIdentifierKey" {
  val arn  = "arn:aws:execute-api:us-east-1:123:abc/prod/GET/me"
  val base = Lambda.Authorizer.allow("u-1", arn)
  val resp = Lambda.Authorizer.withUsageKey(base, "my-api-key")
  match resp.usageIdentifierKey {
    case None    -> assertTrue(false, "usageIdentifierKey must be Some")
    case Some(k) -> assertEqual(k, "my-api-key", "usage key value")
  }
}

test "authorized: returns isAuthorized=true with empty context" {
  val resp = Lambda.Authorizer.authorized()
  assertTrue(resp.isAuthorized, "authorized response has isAuthorized=true")
  assertTrue(resp.context.count == 0, "context is empty")
}

test "authorizedWithContext: returns isAuthorized=true with context" {
  val ctx  = Map.empty[String, String]().set("sub", "user-123")
  val resp = Lambda.Authorizer.authorizedWithContext(ctx)
  assertTrue(resp.isAuthorized, "isAuthorized must be true")
  match resp.context.get("sub") {
    case Some(v) -> assertEqual(v, "user-123", "sub claim in context")
    case None    -> assertTrue(false, "sub must be present in context")
  }
}

test "denied: returns isAuthorized=false" {
  val resp = Lambda.Authorizer.denied()
  assertTrue(not resp.isAuthorized, "denied response has isAuthorized=false")
}
