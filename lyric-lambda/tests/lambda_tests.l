//! tests/lambda_tests.l — tests for the pure-Lyric surface of the Lambda package.
//!
//! Covers LambdaError construction and errorMessage formatting, LambdaApp builder
//! (newApp / onSqs / onSns / onS3 / onEventBridge / onDynamoDb / onKinesis / onRaw /
//! withStreamingHandler / onTokenAuthorizer / onRequestAuthorizer / onHttpAuthorizer),
//! event record construction (SqsEvent, SqsBatchResponse, SnsEvent, S3Event,
//! EventBridgeEvent, DynamoDbEvent, KinesisEvent), and Lambda.Authorizer pure helpers
//! (allow, allowAll, deny, withContext, withUsageKey, authorized,
//! authorizedWithContext, denied).
//! serve() and the kernel runtime loop require the Lambda Runtime API and
//! are not exercised here.
//! Contract-violation tests (e.g. empty handlerName) require assertThrows, which
//! is not yet in Std.Testing; the requires: guards are verified structurally in
//! lambda.l source.
@test_module
package Lambda.LambdaTests

import Std.Core
import Std.Testing
import Std.Collections
import Lambda
import Lambda.Events
import Lambda.Authorizer

// ─── LambdaError ─────────────────────────────────────────────────────────────
// Construct each case via unqualified union construction (a type annotation
// disambiguates) and destructure positionally to assert the stored fields
// directly — not just their rendered errorMessage form (#3519).
test "LambdaError.HandlerError: carries message and errorType" {
  val e: LambdaError = HandlerError("boom", "ValidationError")
  match e {
    case HandlerError(message, errorType) -> {
      assertEqual(message, "boom", "message field")
      assertEqual(errorType, "ValidationError", "errorType field")
    }
    case _ -> assertTrue(false, "expected HandlerError case")
  }
}

test "LambdaError.ParseError: carries message" {
  val e: LambdaError = ParseError("unexpected token")
  match e {
    case ParseError(message) -> assertEqual(message, "unexpected token", "message field")
    case _ -> assertTrue(false, "expected ParseError case")
  }
}

test "LambdaError.TimeoutError: carries remainingMs" {
  val e: LambdaError = TimeoutError(150i64)
  match e {
    case TimeoutError(remainingMs) -> assertTrue(remainingMs == 150i64, "remainingMs field")
    case _ -> assertTrue(false, "expected TimeoutError case")
  }
}

test "LambdaError.InternalError: carries message" {
  val e: LambdaError = InternalError("handler not found")
  match e {
    case InternalError(message) -> assertEqual(message, "handler not found", "message field")
    case _ -> assertTrue(false, "expected InternalError case")
  }
}

// ─── errorMessage ─────────────────────────────────────────────────────────────
test "errorMessage: HandlerError includes errorType and message" {
  val e = Lambda.handlerError("bad input", "ValidationError")
  val msg = Lambda.errorMessage(e)
  assertTrue(msg.contains("ValidationError"), "message includes errorType")
  assertTrue(msg.contains("bad input"), "message includes handler message")
}

test "errorMessage: ParseError includes prefix and message" {
  val e = Lambda.parseError("invalid JSON")
  val msg = Lambda.errorMessage(e)
  assertTrue(msg.contains("ParseError"), "message includes ParseError prefix")
  assertTrue(msg.contains("invalid JSON"), "message includes inner message")
}

test "errorMessage: TimeoutError includes remaining ms" {
  val e = Lambda.timeoutError(42i64)
  val msg = Lambda.errorMessage(e)
  assertTrue(msg.contains("42"), "message includes remaining ms")
  assertTrue(msg.contains("TimeoutError"), "message includes TimeoutError prefix")
}

test "errorMessage: InternalError includes message" {
  val e = Lambda.internalError("DLL not found")
  val msg = Lambda.errorMessage(e)
  assertTrue(msg.contains("InternalError"), "message includes InternalError prefix")
  assertTrue(msg.contains("DLL not found"), "message includes inner message")
}

// ─── LambdaApp builder ───────────────────────────────────────────────────────
test "newApp: creates empty LambdaApp" {
  val app = Lambda.newApp()
  assertTrue(app.eventHandlers.length == 0, "no event handlers initially")
  assertTrue(app.authorizerHandlers.length == 0, "no authorizer handlers initially")
  assertTrue(app.directHandlers.length == 0, "no direct handlers initially")
  match app.httpRouter {
    case None -> ()
    case Some(_) -> assertTrue(false, "httpRouter must be None initially")
  }
}

test "onSqs: registers SQS handler" {
  val app = Lambda.onSqs(Lambda.newApp(), "MyApp.Queue.handle")
  assertEqualInt(app.eventHandlers.length, 1, "one event handler registered")
  assertEqual(app.eventHandlers[0].eventSource, "aws:sqs", "event source")
  assertEqual(app.eventHandlers[0].handlerName, "MyApp.Queue.handle", "handler name")
}

test "onSns: registers SNS handler" {
  val app = Lambda.onSns(Lambda.newApp(), "MyApp.Notify.handle")
  assertEqualInt(app.eventHandlers.length, 1, "one handler")
  assertEqual(app.eventHandlers[0].eventSource, "aws:sns", "event source")
}

test "onS3: registers S3 handler" {
  val app = Lambda.onS3(Lambda.newApp(), "MyApp.Storage.handle")
  assertEqual(app.eventHandlers[0].eventSource, "aws:s3", "event source")
}

test "onEventBridge: registers EventBridge handler" {
  val app = Lambda.onEventBridge(Lambda.newApp(), "MyApp.Events.handle")
  assertEqual(app.eventHandlers[0].eventSource, "aws.events", "event source")
}

test "onDynamoDb: registers DynamoDB handler" {
  val app = Lambda.onDynamoDb(Lambda.newApp(), "MyApp.Dynamo.handle")
  assertEqual(app.eventHandlers[0].eventSource, "aws:dynamodb", "event source")
}

test "onKinesis: registers Kinesis handler" {
  val app = Lambda.onKinesis(Lambda.newApp(), "MyApp.Stream.handle")
  assertEqual(app.eventHandlers[0].eventSource, "aws:kinesis", "event source")
}

test "onRaw: registers catch-all handler" {
  val app = Lambda.onRaw(Lambda.newApp(), "MyApp.Raw.handle")
  assertEqual(app.eventHandlers[0].eventSource, "raw", "event source is raw")
}

// Registration reads inside-out (Queue → Storage → Events): the nested-call
// form is used because the self-hosted compiler has no `|>` pipe operator yet
// (#3520). Re-express as a left-to-right pipeline once pipe support lands.
test "chained event handlers: each produces a unique entry" {
  val app = Lambda.onEventBridge(
    Lambda.onS3(Lambda.onSqs(Lambda.newApp(), "MyApp.Queue.handle"), "MyApp.Storage.handle"),
    "MyApp.Events.handle"
  )
  assertEqualInt(app.eventHandlers.length, 3, "three handlers registered")
}

test "withStreamingHandler: sets streamingHandler name" {
  val app = Lambda.withStreamingHandler(Lambda.newApp(), "MyApp.Stream.handle")
  match app.streamingHandler {
    case None -> assertTrue(false, "streamingHandler must be Some")
    case Some(n) -> assertEqual(n, "MyApp.Stream.handle", "streaming handler name")
  }
}

test "onTokenAuthorizer: registers token authorizer" {
  val app = Lambda.onTokenAuthorizer(Lambda.newApp(), "MyApp.Auth.token")
  assertEqualInt(app.authorizerHandlers.length, 1, "one authorizer registered")
  assertEqual(app.authorizerHandlers[0].authorizerType, "token", "authorizer type")
  assertEqual(app.authorizerHandlers[0].handlerName, "MyApp.Auth.token", "handler name")
}

test "onRequestAuthorizer: registers request authorizer" {
  val app = Lambda.onRequestAuthorizer(Lambda.newApp(), "MyApp.Auth.request")
  assertEqual(app.authorizerHandlers[0].authorizerType, "request", "authorizer type")
}

test "onHttpAuthorizer: registers HTTP API authorizer" {
  val app = Lambda.onHttpAuthorizer(Lambda.newApp(), "MyApp.Auth.http")
  assertEqual(app.authorizerHandlers[0].authorizerType, "http", "authorizer type")
}

// ─── Lambda.Events record construction ───────────────────────────────────────
test "SqsEvent: fields are accessible" {
  val rec = SqsRecord(
    messageId = "msg-1",
    receiptHandle = "rh-1",
    body = "{}",
    attributes = newMap(),
    messageAttributes = newMap(),
    md5OfBody = "abc123",
    eventSource = "aws:sqs",
    eventSourceArn = "arn:aws:sqs:us-east-1:123:my-queue",
    awsRegion = "us-east-1"
  )
  val evt = SqsEvent(records = [rec])
  assertEqualInt(evt.records.length, 1, "one record")
  assertEqual(evt.records[0].messageId, "msg-1", "messageId field")
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
    version = "0",
    id = "evt-uuid",
    source = "my.service",
    account = "123456789012",
    time = "2024-01-01T00:00:00Z",
    region = "us-east-1",
    resources = ["arn:aws:events:us-east-1:123::rule/my-rule"],
    detailType = "OrderPlaced",
    detail = "{\"orderId\":\"o-1\"}"
  )
  assertEqual(evt.source, "my.service", "source field")
  assertEqual(evt.detailType, "OrderPlaced", "detailType field")
  assertEqual(evt.version, "0", "version field")
}

test "KinesisStreamRecord: fields are accessible" {
  val kRec = KinesisRecord(
    kinesisSchemaVersion = "1.0",
    partitionKey = "pk-1",
    sequenceNumber = "seq-1",
    data = "SGVsbG8=",
    approximateArrivalTimestamp = 1700000000.0
  )
  val rec = KinesisStreamRecord(
    kinesis = kRec,
    eventSource = "aws:kinesis",
    eventVersion = "1.0",
    eventId = "eid-1",
    eventName = "aws:kinesis:record",
    invokeIdentityArn = "arn:aws:iam::123:role/my-role",
    awsRegion = "us-east-1",
    eventSourceArn = "arn:aws:kinesis:us-east-1:123:stream/my-stream"
  )
  val evt = KinesisEvent(records = [rec])
  assertEqualInt(evt.records.length, 1, "one record")
  assertEqual(evt.records[0].kinesis.partitionKey, "pk-1", "partitionKey")
  assertEqual(evt.records[0].eventSource, "aws:kinesis", "eventSource")
}

test "SnsEvent: fields are accessible" {
  val msg = SnsMessage(
    messageId = "sns-msg-1",
    topicArn = "arn:aws:sns:us-east-1:123:my-topic",
    subject = Some("Test Subject"),
    message = "hello from SNS",
    timestamp = "2024-01-01T00:00:00.000Z",
    signatureVersion = "1",
    signature = "sig==",
    signingCertUrl = "https://sns.amazonaws.com/cert.pem",
    unsubscribeUrl = "https://sns.amazonaws.com/unsubscribe",
    messageAttributes = newMap()
  )
  val rec = SnsRecord(
    eventSource = "aws:sns",
    eventVersion = "1.0",
    eventSubscriptionArn = "arn:aws:sns:us-east-1:123:my-topic:sub-1",
    sns = msg
  )
  val evt = SnsEvent(records = [rec])
  assertEqualInt(evt.records.length, 1, "one record")
  assertEqual(evt.records[0].eventSource, "aws:sns", "eventSource field")
  assertEqual(evt.records[0].sns.message, "hello from SNS", "sns.message field")
  match evt.records[0].sns.subject {
    case Some(s) -> assertEqual(s, "Test Subject", "sns.subject field")
    case None -> assertTrue(false, "subject must be Some")
  }
}

test "S3Event: fields are accessible" {
  val s3obj = S3Object(key = "images%2Fphoto.png", size = 12345i64, eTag = "etag-1", sequencer = "seq-1")
  val bucket = S3Bucket(name = "my-bucket", ownerIdentity = newMap(), arn = "arn:aws:s3:::my-bucket")
  val detail = S3Detail(s3SchemaVersion = "1.0", configurationId = "MyConfig", bucket = bucket, object = s3obj)
  val rec = S3Record(
    eventVersion = "2.1",
    eventSource = "aws:s3",
    awsRegion = "us-east-1",
    eventTime = "2024-01-01T00:00:00.000Z",
    eventName = "ObjectCreated:Put",
    userIdentity = newMap(),
    requestParameters = S3RequestParameters(sourceIpAddress = "1.2.3.4"),
    responseElements = S3ResponseElements(xAmzRequestId = "req-1", xAmzId2 = "id-2"),
    s3 = detail
  )
  val evt = S3Event(records = [rec])
  assertEqualInt(evt.records.length, 1, "one record")
  assertEqual(evt.records[0].eventSource, "aws:s3", "eventSource field")
  assertEqual(evt.records[0].eventName, "ObjectCreated:Put", "eventName field")
  assertEqual(evt.records[0].s3.bucket.name, "my-bucket", "bucket name field")
  assertEqual(evt.records[0].s3.object.key, "images%2Fphoto.png", "object key field (URL-encoded)")
}

test "DynamoDbEvent: fields are accessible" {
  val keyAttr = DynamoDbAttributeValue(
    s = Some("pk-1"),
    n = None,
    b = None,
    bool = None,
    null = None,
    ss = None,
    ns = None,
    bs = None
  )
  val dynKeys: Map[String, DynamoDbAttributeValue] = newMap()
  dynKeys.add("id", keyAttr)
  val streamRec = DynamoDbStreamRecord(
    approximateCreationDateTime = Some(1700000000i64),
    keys = dynKeys,
    newImage = None,
    oldImage = None,
    sequenceNumber = "seq-1",
    sizeBytes = 42i64,
    streamViewType = "KEYS_ONLY"
  )
  val rec = DynamoDbRecord(
    eventId = "evt-1",
    eventVersion = "1.1",
    eventSource = "aws:dynamodb",
    eventName = "INSERT",
    awsRegion = "us-east-1",
    dynamodb = streamRec,
    eventSourceArn = "arn:aws:dynamodb:us-east-1:123:table/my-table/stream/2024-01-01"
  )
  val evt = DynamoDbEvent(records = [rec])
  assertEqualInt(evt.records.length, 1, "one record")
  assertEqual(evt.records[0].eventSource, "aws:dynamodb", "eventSource field")
  assertEqual(evt.records[0].eventName, "INSERT", "eventName field")
  assertEqual(evt.records[0].dynamodb.streamViewType, "KEYS_ONLY", "streamViewType field")
  match evt.records[0].dynamodb.approximateCreationDateTime {
    case Some(t) -> assertTrue(t == 1700000000i64, "approximateCreationDateTime field")
    case None -> assertTrue(false, "must have approximateCreationDateTime")
  }
  match mapGet(evt.records[0].dynamodb.keys, "id") {
    case Some(attr) -> {
      match attr.s {
        case Some(v) -> assertEqual(v, "pk-1", "key attribute string value")
        case None -> assertTrue(false, "key attribute must have s field")
      }
    }
    case None -> assertTrue(false, "must have id key in dynamodb.keys")
  }
}

// ─── Lambda.Authorizer pure helpers ──────────────────────────────────────────
test "IamEffect.Allow: can be matched" {
  val eff = IamEffect.Allow
  match eff {
    case IamEffect.Allow -> ()
    case _ -> assertTrue(false, "expected Allow")
  }
}

test "IamEffect.Deny: can be matched" {
  val eff = IamEffect.Deny
  match eff {
    case IamEffect.Deny -> ()
    case _ -> assertTrue(false, "expected Deny")
  }
}

test "allow: returns AuthorizerResponse with Allow effect" {
  val arn = "arn:aws:execute-api:us-east-1:123:abc/prod/GET/users"
  val resp = Lambda.Authorizer.allow("user-42", arn)
  assertEqual(resp.principalId, "user-42", "principalId")
  assertEqualInt(resp.policyDocument.statement.length, 1, "one statement")
  match resp.policyDocument.statement[0].effect {
    case IamEffect.Allow -> ()
    case _ -> assertTrue(false, "effect must be Allow")
  }
  assertEqual(resp.policyDocument.statement[0].resource[0], arn, "resource ARN")
}

test "deny: returns AuthorizerResponse with Deny effect" {
  val arn = "arn:aws:execute-api:us-east-1:123:abc/prod/DELETE/admin"
  val resp = Lambda.Authorizer.deny("anon", arn)
  match resp.policyDocument.statement[0].effect {
    case IamEffect.Deny -> ()
    case _ -> assertTrue(false, "effect must be Deny")
  }
}

test "allowAll: resource is exact api/stage wildcard ARN" {
  val methodArn = "arn:aws:execute-api:us-east-1:123:abc123/prod/GET/users"
  val resp = Lambda.Authorizer.allowAll("user-42", methodArn)
  val resource = resp.policyDocument.statement[0].resource[0]
  assertEqual(
    resource,
    "arn:aws:execute-api:us-east-1:123:abc123/prod/*",
    "allowAll produces exact api/stage wildcard ARN"
  )
}

test "withContext: attaches context map to response" {
  val arn = "arn:aws:execute-api:us-east-1:123:abc/prod/GET/me"
  val base = Lambda.Authorizer.allow("u-1", arn)
  val ctx: Map[String, String] = newMap()
  ctx.add("userId", "u-1")
  ctx.add("role", "admin")
  val resp = Lambda.Authorizer.withContext(base, ctx)
  match mapGet(resp.context, "userId") {
    case Some(v) -> assertEqual(v, "u-1", "userId in context")
    case None -> assertTrue(false, "userId must be in context")
  }
  match mapGet(resp.context, "role") {
    case Some(v) -> assertEqual(v, "admin", "role in context")
    case None -> assertTrue(false, "role must be in context")
  }
}

test "withUsageKey: sets usageIdentifierKey" {
  val arn = "arn:aws:execute-api:us-east-1:123:abc/prod/GET/me"
  val base = Lambda.Authorizer.allow("u-1", arn)
  val resp = Lambda.Authorizer.withUsageKey(base, "my-api-key")
  match resp.usageIdentifierKey {
    case None -> assertTrue(false, "usageIdentifierKey must be Some")
    case Some(k) -> assertEqual(k, "my-api-key", "usage key value")
  }
}

test "authorized: returns isAuthorized=true with empty context" {
  val resp = Lambda.Authorizer.authorized()
  assertTrue(resp.isAuthorized, "authorized response has isAuthorized=true")
  assertTrue(resp.context.count == 0, "context is empty")
}

test "authorizedWithContext: returns isAuthorized=true with context" {
  val ctx: Map[String, String] = newMap()
  ctx.add("sub", "user-123")
  val resp = Lambda.Authorizer.authorizedWithContext(ctx)
  assertTrue(resp.isAuthorized, "isAuthorized must be true")
  match mapGet(resp.context, "sub") {
    case Some(v) -> assertEqual(v, "user-123", "sub claim in context")
    case None -> assertTrue(false, "sub must be present in context")
  }
}

test "denied: returns isAuthorized=false" {
  val resp = Lambda.Authorizer.denied()
  assertTrue(not resp.isAuthorized, "denied response has isAuthorized=false")
}
