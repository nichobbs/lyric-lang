//! tests/lambda_dispatch_tests.l — tests for `Lambda.Dispatch`: event-source
//! detection, JSON decode/encode, and `Lambda.Direct` dispatch resolution.
//!
//! Deliberately pure / no I/O: every case here feeds a literal JSON string
//! straight to `detectEventSource`/`dispatchInvocation` and asserts the
//! result, so it needs no live network, no mock server process, and no
//! concurrency primitive. The wire-level transport (`pollAndDispatchOnce`'s
//! GET-next/POST-response HTTP round trip, `runLocalServer`'s accept loop)
//! is exercised instead via a manual two-process verification described in
//! this PR's implementation report — see that report for why: this
//! repository's `Std.Task.Scope.scopeSpawn` has an open bug on `--target
//! dotnet` where the scheduled closure is never invoked (issue #5329,
//! `lyric-stdlib/tests/task_scope_known_failures_tests.l`), and the newer
//! `scope { } / spawn e / await t` keyword form is degenerate-synchronous
//! on `--target dotnet` (no real concurrency at all — see
//! `async_spawn_self_test.l`'s header comment) — so there is currently no
//! way to run a mock HTTP server on a background thread inside a single
//! `lyric test` process on this target. A test that shelled out to a
//! separately-started mock server process would work, but would not be
//! self-contained / CI-safe the way every other file in this suite is.
//!
//! Handlers below are zero-field records implementing `Lambda`'s handler
//! interfaces (`SqsHandler`, `RawHandler`, ...) rather than bare functions
//! or closures — `docs/03-decision-log.md`'s "Decision 4" entry found that
//! a bare named function used as a function-typed value crashes at runtime
//! (#5362) and that closures invoked across 2+ packages are unreliable on
//! this backend (#5363), both of which this dispatch path would hit.
@test_module
package Lambda.DispatchTests

import Std.Core
import Std.Testing
import Std.Collections
import Lambda
import Lambda.Direct
import Lambda.Events
import Lambda.Authorizer
import Lambda.Dispatch

func testContext(): LambdaContext {
  return LambdaContext(
    functionName = "test-fn",
    functionVersion = "$LATEST",
    invokedFunctionArn = "arn:aws:lambda:us-east-1:123456789012:function:test-fn",
    memoryLimitInMb = 128,
    requestId = "req-1",
    logGroupName = "/aws/lambda/test-fn",
    logStreamName = "2026/07/11/[$LATEST]abc",
    remainingTimeMs = 5000i64
  )
}

// ─── detectEventSource ────────────────────────────────────────────────────────
test "detectEventSource: API Gateway v1 (REST API)" {
  val payload = "{\"httpMethod\":\"GET\",\"requestContext\":{\"resourceId\":\"abc\"}}"
  match detectEventSource(payload) {
    case ApiGwV1Src -> ()
    case _ -> assertTrue(false, "expected ApiGwV1Src")
  }
}

test "detectEventSource: API Gateway v2 (HTTP API)" {
  val payload = "{\"version\":\"2.0\",\"routeKey\":\"GET /x\",\"requestContext\":{\"http\":{\"method\":\"GET\"}}}"
  match detectEventSource(payload) {
    case ApiGwV2Src -> ()
    case _ -> assertTrue(false, "expected ApiGwV2Src")
  }
}

test "detectEventSource: ALB" {
  val payload = "{\"httpMethod\":\"GET\",\"requestContext\":{\"elb\":{\"targetGroupArn\":\"arn:x\"}}}"
  match detectEventSource(payload) {
    case AlbSrc -> ()
    case _ -> assertTrue(false, "expected AlbSrc")
  }
}

test "detectEventSource: SQS" {
  match detectEventSource("{\"Records\":[{\"eventSource\":\"aws:sqs\"}]}") {
    case SqsSrc -> ()
    case _ -> assertTrue(false, "expected SqsSrc")
  }
}

test "detectEventSource: SNS" {
  match detectEventSource("{\"Records\":[{\"eventSource\":\"aws:sns\"}]}") {
    case SnsSrc -> ()
    case _ -> assertTrue(false, "expected SnsSrc")
  }
}

// AWS's real SNS-to-Lambda event uses "EventSource" (PascalCase), not the
// lowerCamelCase "eventSource" every other event source uses — regression
// coverage for the case-insensitive fallback in firstRecordEventSource.
test "detectEventSource: SNS with the real AWS PascalCase EventSource key" {
  val payload = "{\"Records\":[{\"EventVersion\":\"1.0\",\"EventSubscriptionArn\":\"arn:aws:sns:us-east-2:123456789012:sns-lambda:21be56ed\"," +
    "\"EventSource\":\"aws:sns\",\"Sns\":{\"MessageId\":\"95df01b4\",\"TopicArn\":\"arn:aws:sns:us-east-2:123456789012:sns-lambda\"," +
    "\"Message\":\"Hello from SNS!\"}}]}"
  match detectEventSource(payload) {
    case SnsSrc -> ()
    case _ -> assertTrue(false, "expected SnsSrc for the real PascalCase AWS SNS event shape")
  }
}

test "detectEventSource: S3" {
  match detectEventSource("{\"Records\":[{\"eventSource\":\"aws:s3\"}]}") {
    case S3Src -> ()
    case _ -> assertTrue(false, "expected S3Src")
  }
}

test "detectEventSource: DynamoDB Streams" {
  match detectEventSource("{\"Records\":[{\"eventSource\":\"aws:dynamodb\"}]}") {
    case DynamoDbSrc -> ()
    case _ -> assertTrue(false, "expected DynamoDbSrc")
  }
}

test "detectEventSource: Kinesis" {
  match detectEventSource("{\"Records\":[{\"eventSource\":\"aws:kinesis\"}]}") {
    case KinesisSrc -> ()
    case _ -> assertTrue(false, "expected KinesisSrc")
  }
}

test "detectEventSource: EventBridge" {
  val payload = "{\"source\":\"my.service\",\"detail-type\":\"OrderPlaced\",\"detail\":\"{}\"}"
  match detectEventSource(payload) {
    case EventBridgeSrc -> ()
    case _ -> assertTrue(false, "expected EventBridgeSrc")
  }
}

test "detectEventSource: REST API TOKEN authorizer" {
  val payload = "{\"type\":\"TOKEN\",\"authorizationToken\":\"Bearer xyz\",\"methodArn\":\"arn:x\"}"
  match detectEventSource(payload) {
    case TokenAuthSrc -> ()
    case _ -> assertTrue(false, "expected TokenAuthSrc")
  }
}

test "detectEventSource: REST API REQUEST authorizer" {
  val payload = "{\"type\":\"REQUEST\",\"methodArn\":\"arn:x\",\"requestContext\":{\"accountId\":\"1\"}}"
  match detectEventSource(payload) {
    case RequestAuthSrc -> ()
    case _ -> assertTrue(false, "expected RequestAuthSrc")
  }
}

test "detectEventSource: HTTP API (v2) authorizer" {
  val payload = "{\"version\":\"2.0\",\"type\":\"REQUEST\",\"routeArn\":\"arn:x\",\"identitySource\":[\"Bearer xyz\"]}"
  match detectEventSource(payload) {
    case HttpAuthSrc -> ()
    case _ -> assertTrue(false, "expected HttpAuthSrc")
  }
}

test "detectEventSource: unrecognised JSON falls back to raw" {
  match detectEventSource("{\"foo\":\"bar\"}") {
    case RawSrc -> ()
    case _ -> assertTrue(false, "expected RawSrc for unrecognised JSON")
  }
}

test "detectEventSource: malformed (non-JSON) payload falls back to raw instead of panicking" {
  match detectEventSource("not json at all {") {
    case RawSrc -> ()
    case _ -> assertTrue(false, "expected RawSrc for malformed payload")
  }
}

// ─── dispatchInvocation: aws:sqs ──────────────────────────────────────────────
record SqsOkHandler {
}

impl Lambda.SqsHandler for SqsOkHandler {
  func handle(event: in SqsEvent, ctx: in LambdaContext): Result[Unit, LambdaError] {
    assertEqualInt(event.records.length, 1, "sqs handler sees one record")
    assertEqual(event.records[0].messageId, "msg-1", "messageId decoded")
    assertEqual(event.records[0].body, "hello sqs", "body decoded")
    assertEqual(
      event.records[0].eventSourceArn,
      "arn:aws:sqs:us-east-1:123456789012:my-queue",
      "eventSourceArn decoded from the real AWS key eventSourceARN"
    )
    assertEqual(ctx.requestId, "req-1", "handler receives the dispatch-time LambdaContext")
    return Ok(value = ())
  }
}

// A module-level `val` here (rather than this function) reproducibly
// crashed the whole test type's static initializer at runtime with no
// diagnostic beyond "type initializer... threw an exception" — unrelated
// to the interface-vs-closure dispatch fix above, and out of scope to
// root-cause further; a plain function sidesteps it.
func sqsPayload(): String {
  return "{\"Records\":[{\"messageId\":\"msg-1\",\"receiptHandle\":\"rh-1\",\"body\":\"hello sqs\"," +
    "\"attributes\":{\"ApproximateReceiveCount\":\"1\"},\"messageAttributes\":{}," +
    "\"md5OfBody\":\"abc123\",\"eventSource\":\"aws:sqs\"," +
    "\"eventSourceARN\":\"arn:aws:sqs:us-east-1:123456789012:my-queue\",\"awsRegion\":\"us-east-1\"}]}"
}

test "dispatchInvocation: aws:sqs decodes the event and invokes the registered SqsDirect handler" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.sqsHandler(SqsOkHandler()))
  match dispatchInvocation(app, sqsPayload(), testContext()) {
    case Ok(body) -> assertEqual(body, "null", "whole-batch success response body")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

record SqsBatchHandlerImpl {
}

impl Lambda.SqsBatchHandler for SqsBatchHandlerImpl {
  func handle(event: in SqsEvent, ctx: in LambdaContext): Result[SqsBatchResponse, LambdaError] {
    return Ok(
      value = SqsBatchResponse(
        batchItemFailures = [SqsBatchItemFailure(itemIdentifier = event.records[0].messageId)]
      )
    )
  }
}

test "dispatchInvocation: aws:sqs partial-batch response is encoded correctly" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.sqsBatchHandler(SqsBatchHandlerImpl()))
  match dispatchInvocation(app, sqsPayload(), testContext()) {
    case Ok(body) -> assertEqual(body, "{\"batchItemFailures\":[{\"itemIdentifier\":\"msg-1\"}]}", "batch response JSON")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

record SqsFailHandler {
}

impl Lambda.SqsHandler for SqsFailHandler {
  func handle(event: in SqsEvent, ctx: in LambdaContext): Result[Unit, LambdaError] {
    return Err(error = HandlerError(message = "boom", errorType = "BoomError"))
  }
}

test "dispatchInvocation: aws:sqs handler Err propagates as the LambdaError" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.sqsHandler(SqsFailHandler()))
  match dispatchInvocation(app, sqsPayload(), testContext()) {
    case Ok(_) -> assertTrue(false, "expected Err")
    case Err(HandlerError(msg, t)) -> {
      assertEqual(msg, "boom", "handler error message propagates")
      assertEqual(t, "BoomError", "handler error type propagates")
    }
    case Err(other) -> assertTrue(false, "expected HandlerError, got: " + Lambda.errorMessage(other))
  }
}

test "dispatchInvocation: aws:sqs with no registered handler fails closed with InternalError" {
  match dispatchInvocation(Lambda.newApp(), sqsPayload(), testContext()) {
    case Ok(_) -> assertTrue(false, "expected Err when no aws:sqs handler is registered")
    case Err(InternalError(msg)) -> assertTrue(msg.contains("aws:sqs"), "error names the missing event source")
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

// ─── dispatchInvocation: aws:sns ──────────────────────────────────────────────
record SnsOkHandler {
}

impl Lambda.SnsHandler for SnsOkHandler {
  func handle(event: in SnsEvent, ctx: in LambdaContext): Result[Unit, LambdaError] {
    assertEqualInt(event.records.length, 1, "sns handler sees one record")
    assertEqual(event.records[0].eventSource, "aws:sns", "eventSource decoded from the real AWS key EventSource")
    assertEqual(
      event.records[0].eventSubscriptionArn,
      "arn:aws:sns:us-east-2:123456789012:sns-lambda:21be56ed-a058-49f5-8c98-aedd2564c486",
      "eventSubscriptionArn decoded"
    )
    assertEqual(event.records[0].sns.messageId, "95df01b4-ee98-5cb9-9903-4c221d41eb5e", "sns.messageId decoded")
    assertEqual(event.records[0].sns.topicArn, "arn:aws:sns:us-east-2:123456789012:sns-lambda", "sns.topicArn decoded")
    assertEqual(event.records[0].sns.message, "Hello from SNS!", "sns.message decoded")
    match event.records[0].sns.subject {
      case Some(s) -> assertEqual(s, "TestInvoke", "sns.subject decoded")
      case None -> assertTrue(false, "sns.subject must be Some")
    }
    match mapGet(event.records[0].sns.messageAttributes, "Test") {
      case Some(attr) -> {
        assertEqual(attr.attributeType, "String", "message attribute Type decoded")
        assertEqual(attr.value, "TestString", "message attribute Value decoded")
      }
      case None -> assertTrue(false, "sns.messageAttributes must contain Test")
    }
    return Ok(value = ())
  }
}

func snsPayload(): String {
  return "{\"Records\":[{\"EventVersion\":\"1.0\"," +
    "\"EventSubscriptionArn\":\"arn:aws:sns:us-east-2:123456789012:sns-lambda:21be56ed-a058-49f5-8c98-aedd2564c486\"," +
    "\"EventSource\":\"aws:sns\",\"Sns\":{\"SignatureVersion\":\"1\",\"Timestamp\":\"2019-01-02T12:45:07.000Z\"," +
    "\"Signature\":\"tcc6faL2yUC6dgZdmrwh1Y4cGa\",\"SigningCertUrl\":\"https://sns.us-east-2.amazonaws.com/cert.pem\"," +
    "\"MessageId\":\"95df01b4-ee98-5cb9-9903-4c221d41eb5e\",\"Message\":\"Hello from SNS!\"," +
    "\"MessageAttributes\":{\"Test\":{\"Type\":\"String\",\"Value\":\"TestString\"}," +
    "\"TestBinary\":{\"Type\":\"Binary\",\"Value\":\"TestBinary\"}},\"Type\":\"Notification\"," +
    "\"UnsubscribeUrl\":\"https://sns.us-east-2.amazonaws.com/unsubscribe\"," +
    "\"TopicArn\":\"arn:aws:sns:us-east-2:123456789012:sns-lambda\",\"Subject\":\"TestInvoke\"}}]}"
}

test "dispatchInvocation: aws:sns decodes the real PascalCase AWS event and invokes the registered SnsDirect handler" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.snsHandler(SnsOkHandler()))
  match dispatchInvocation(app, snsPayload(), testContext()) {
    case Ok(body) -> assertEqual(body, "null", "sns handler success response body")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

test "dispatchInvocation: aws:sns with no registered handler fails closed with InternalError" {
  match dispatchInvocation(Lambda.newApp(), snsPayload(), testContext()) {
    case Ok(_) -> assertTrue(false, "expected Err when no aws:sns handler is registered")
    case Err(InternalError(msg)) -> {
      assertTrue(msg.contains("aws:sns"), "error names the missing event source")
      assertTrue(msg.contains("snsHandler"), "error names the Lambda.Direct.snsHandler factory")
    }
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

// ─── dispatchInvocation: aws:s3 ───────────────────────────────────────────────
record S3OkHandler {
}

impl Lambda.S3Handler for S3OkHandler {
  func handle(event: in S3Event, ctx: in LambdaContext): Result[Unit, LambdaError] {
    assertEqualInt(event.records.length, 1, "s3 handler sees one record")
    assertEqual(event.records[0].eventName, "ObjectCreated:Put", "eventName decoded")
    assertEqual(
      event.records[0].requestParameters.sourceIpAddress,
      "205.255.255.255",
      "sourceIpAddress decoded from the real AWS key sourceIPAddress"
    )
    assertEqual(
      event.records[0].responseElements.xAmzRequestId,
      "D82B88E5F771F645",
      "xAmzRequestId decoded from the hyphenated real AWS key x-amz-request-id"
    )
    assertEqual(
      event.records[0].responseElements.xAmzId2,
      "vlR7PnpV2Ce81l0PRw6jlUpck7Jo5ZsQjryTjKlc5aLWGVHPZLj5NeC6qMa0emYBDXOo6QBU0Wo=",
      "xAmzId2 decoded from the hyphenated real AWS key x-amz-id-2"
    )
    assertEqual(event.records[0].s3.bucket.name, "lambda-artifacts-deafc19498e3f2df", "bucket name decoded")
    assertEqual(event.records[0].s3.object.key, "b21b84d653bb07b05b1e6b33684dc11b", "object key decoded")
    assertEqualLong(event.records[0].s3.object.size, 1305107i64, "object size decoded")
    return Ok(value = ())
  }
}

func s3Payload(): String {
  return "{\"Records\":[{\"eventVersion\":\"2.1\",\"eventSource\":\"aws:s3\",\"awsRegion\":\"us-east-2\"," +
    "\"eventTime\":\"2019-09-03T19:37:27.192Z\",\"eventName\":\"ObjectCreated:Put\"," +
    "\"userIdentity\":{\"principalId\":\"AWS:AIDAINPONIXQXHT3IKHL2\"}," +
    "\"requestParameters\":{\"sourceIPAddress\":\"205.255.255.255\"}," +
    "\"responseElements\":{\"x-amz-request-id\":\"D82B88E5F771F645\"," +
    "\"x-amz-id-2\":\"vlR7PnpV2Ce81l0PRw6jlUpck7Jo5ZsQjryTjKlc5aLWGVHPZLj5NeC6qMa0emYBDXOo6QBU0Wo=\"}," +
    "\"s3\":{\"s3SchemaVersion\":\"1.0\",\"configurationId\":\"828aa6fc-f7b5-4305-8584-487c791949c1\"," +
    "\"bucket\":{\"name\":\"lambda-artifacts-deafc19498e3f2df\"," +
    "\"ownerIdentity\":{\"principalId\":\"A3I5XTEXAMAI3E\"}," +
    "\"arn\":\"arn:aws:s3:::lambda-artifacts-deafc19498e3f2df\"}," +
    "\"object\":{\"key\":\"b21b84d653bb07b05b1e6b33684dc11b\",\"size\":1305107," +
    "\"eTag\":\"b21b84d653bb07b05b1e6b33684dc11b\",\"sequencer\":\"0C0F6F405D6ED209E1\"}}}]}"
}

test "dispatchInvocation: aws:s3 decodes the event (incl. sourceIPAddress/x-amz-* quirks) and invokes the registered S3Direct handler" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.s3Handler(S3OkHandler()))
  match dispatchInvocation(app, s3Payload(), testContext()) {
    case Ok(body) -> assertEqual(body, "null", "s3 handler success response body")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

test "dispatchInvocation: aws:s3 with no registered handler fails closed with InternalError" {
  match dispatchInvocation(Lambda.newApp(), s3Payload(), testContext()) {
    case Ok(_) -> assertTrue(false, "expected Err when no aws:s3 handler is registered")
    case Err(InternalError(msg)) -> {
      assertTrue(msg.contains("aws:s3"), "error names the missing event source")
      assertTrue(msg.contains("s3Handler"), "error names the Lambda.Direct.s3Handler factory")
    }
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

// ─── dispatchInvocation: aws:dynamodb ─────────────────────────────────────────
record DynamoDbOkHandler {
}

impl Lambda.DynamoDbHandler for DynamoDbOkHandler {
  func handle(event: in DynamoDbEvent, ctx: in LambdaContext): Result[Unit, LambdaError] {
    assertEqualInt(event.records.length, 1, "dynamodb handler sees one record")
    assertEqual(event.records[0].eventId, "1", "eventId decoded from the real AWS key eventID")
    assertEqual(event.records[0].eventName, "INSERT", "eventName decoded")
    assertEqual(
      event.records[0].eventSourceArn,
      "arn:aws:dynamodb:us-east-1:123456789012:table/ExampleTableWithStream/stream/2015-06-27T00:48:05.899",
      "eventSourceArn decoded from the real AWS key eventSourceARN"
    )
    assertEqual(event.records[0].dynamodb.streamViewType, "NEW_AND_OLD_IMAGES", "streamViewType decoded")
    assertEqualLong(event.records[0].dynamodb.sizeBytes, 26i64, "sizeBytes decoded")
    match mapGet(event.records[0].dynamodb.keys, "Id") {
      case Some(attr) -> match attr.n { case Some(v) -> assertEqual(v, "101", "Keys.Id.N decoded from the DynamoDB wire attribute-value shape"); case None -> assertTrue(false, "Keys.Id must have an N field") }
      case None -> assertTrue(false, "dynamodb.keys must contain Id")
    }
    match event.records[0].dynamodb.newImage {
      case Some(img) -> match mapGet(img, "Message") { case Some(attr) -> match attr.s { case Some(v) -> assertEqual(v, "New item!", "NewImage.Message.S decoded"); case None -> assertTrue(false, "NewImage.Message must have an S field") }; case None -> assertTrue(false, "newImage must contain Message") }
      case None -> assertTrue(false, "newImage must be Some for a NEW_AND_OLD_IMAGES stream view")
    }
    return Ok(value = ())
  }
}

func dynamoDbPayload(): String {
  return "{\"Records\":[{\"eventID\":\"1\",\"eventVersion\":\"1.0\"," +
    "\"dynamodb\":{\"Keys\":{\"Id\":{\"N\":\"101\"}}," +
    "\"NewImage\":{\"Message\":{\"S\":\"New item!\"},\"Id\":{\"N\":\"101\"}}," +
    "\"StreamViewType\":\"NEW_AND_OLD_IMAGES\",\"SequenceNumber\":\"111\",\"SizeBytes\":26}," +
    "\"awsRegion\":\"us-west-2\",\"eventName\":\"INSERT\"," +
    "\"eventSourceARN\":\"arn:aws:dynamodb:us-east-1:123456789012:table/ExampleTableWithStream/stream/2015-06-27T00:48:05.899\"," +
    "\"eventSource\":\"aws:dynamodb\"}]}"
}

test "dispatchInvocation: aws:dynamodb decodes the DynamoDB wire attribute shape and invokes the registered DynamoDbDirect handler" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.dynamoDbHandler(DynamoDbOkHandler()))
  match dispatchInvocation(app, dynamoDbPayload(), testContext()) {
    case Ok(body) -> assertEqual(body, "null", "dynamodb handler success response body")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

test "dispatchInvocation: aws:dynamodb with no registered handler fails closed with InternalError" {
  match dispatchInvocation(Lambda.newApp(), dynamoDbPayload(), testContext()) {
    case Ok(_) -> assertTrue(false, "expected Err when no aws:dynamodb handler is registered")
    case Err(InternalError(msg)) -> {
      assertTrue(msg.contains("aws:dynamodb"), "error names the missing event source")
      assertTrue(msg.contains("dynamoDbHandler"), "error names the Lambda.Direct.dynamoDbHandler factory")
    }
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

// ─── dispatchInvocation: aws:kinesis ──────────────────────────────────────────
record KinesisOkHandler {
}

impl Lambda.KinesisHandler for KinesisOkHandler {
  func handle(event: in KinesisEvent, ctx: in LambdaContext): Result[Unit, LambdaError] {
    assertEqualInt(event.records.length, 1, "kinesis handler sees one record")
    assertEqual(
      event.records[0].eventId,
      "shardId-000000000006:49590338271490256608559692538361571095921575989136588898",
      "eventId decoded from the real AWS key eventID"
    )
    assertEqual(
      event.records[0].eventSourceArn,
      "arn:aws:kinesis:us-east-2:123456789012:stream/lambda-stream",
      "eventSourceArn decoded from the real AWS key eventSourceARN"
    )
    assertEqual(event.records[0].kinesis.partitionKey, "1", "kinesis.partitionKey decoded")
    assertEqual(
      event.records[0].kinesis.data,
      "SGVsbG8sIHRoaXMgaXMgYSB0ZXN0Lg==",
      "kinesis.data decoded as the untouched base64 string"
    )
    val ts = event.records[0].kinesis.approximateArrivalTimestamp
    assertTrue(ts > 1545084650.9 and ts < 1545084651.1, "approximateArrivalTimestamp decoded as a fractional epoch")
    return Ok(value = ())
  }
}

func kinesisPayload(): String {
  return "{\"Records\":[{\"kinesis\":{\"kinesisSchemaVersion\":\"1.0\",\"partitionKey\":\"1\"," +
    "\"sequenceNumber\":\"49590338271490256608559692538361571095921575989136588898\"," +
    "\"data\":\"SGVsbG8sIHRoaXMgaXMgYSB0ZXN0Lg==\",\"approximateArrivalTimestamp\":1545084650.987}," +
    "\"eventSource\":\"aws:kinesis\",\"eventVersion\":\"1.0\"," +
    "\"eventID\":\"shardId-000000000006:49590338271490256608559692538361571095921575989136588898\"," +
    "\"eventName\":\"aws:kinesis:record\",\"invokeIdentityArn\":\"arn:aws:iam::123456789012:role/lambda-role\"," +
    "\"awsRegion\":\"us-east-2\",\"eventSourceARN\":\"arn:aws:kinesis:us-east-2:123456789012:stream/lambda-stream\"}]}"
}

test "dispatchInvocation: aws:kinesis decodes the event and invokes the registered KinesisDirect handler" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.kinesisHandler(KinesisOkHandler()))
  match dispatchInvocation(app, kinesisPayload(), testContext()) {
    case Ok(body) -> assertEqual(body, "null", "kinesis handler success response body")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

test "dispatchInvocation: aws:kinesis with no registered handler fails closed with InternalError" {
  match dispatchInvocation(Lambda.newApp(), kinesisPayload(), testContext()) {
    case Ok(_) -> assertTrue(false, "expected Err when no aws:kinesis handler is registered")
    case Err(InternalError(msg)) -> {
      assertTrue(msg.contains("aws:kinesis"), "error names the missing event source")
      assertTrue(msg.contains("kinesisHandler"), "error names the Lambda.Direct.kinesisHandler factory")
    }
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

// ─── dispatchInvocation: EventBridge ──────────────────────────────────────────
record EventBridgeOkHandler {
}

impl Lambda.EventBridgeHandler for EventBridgeOkHandler {
  func handle(event: in EventBridgeEvent, ctx: in LambdaContext): Result[Unit, LambdaError] {
    assertEqual(event.source, "aws.ec2", "source decoded")
    assertEqual(
      event.detailType,
      "EC2 Instance State-change Notification",
      "detailType decoded from the hyphenated real AWS key detail-type"
    )
    assertEqual(event.id, "6a7e8feb-b491-4cf7-a9f1-bf3703467718", "id decoded")
    assertEqual(event.account, "111122223333", "account decoded")
    assertEqualInt(event.resources.length, 1, "one resource ARN")
    assertEqual(
      event.resources[0],
      "arn:aws:ec2:us-west-1:123456789012:instance/i-1234567890abcdef0",
      "resources[0] decoded"
    )
    assertTrue(event.detail.contains("\"state\":\"terminated\""), "detail kept as raw JSON text")
    return Ok(value = ())
  }
}

func eventBridgePayload(): String {
  return "{\"version\":\"0\",\"id\":\"6a7e8feb-b491-4cf7-a9f1-bf3703467718\"," +
    "\"detail-type\":\"EC2 Instance State-change Notification\",\"source\":\"aws.ec2\"," +
    "\"account\":\"111122223333\",\"time\":\"2017-12-22T18:43:48Z\",\"region\":\"us-west-1\"," +
    "\"resources\":[\"arn:aws:ec2:us-west-1:123456789012:instance/i-1234567890abcdef0\"]," +
    "\"detail\":{\"instance-id\":\"i-1234567890abcdef0\",\"state\":\"terminated\"}}"
}

test "dispatchInvocation: EventBridge decodes the root-level envelope (no Records wrapper) and invokes the registered handler" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.eventBridgeHandler(EventBridgeOkHandler()))
  match dispatchInvocation(app, eventBridgePayload(), testContext()) {
    case Ok(body) -> assertEqual(body, "null", "EventBridge handler success response body")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

test "dispatchInvocation: EventBridge with no registered handler fails closed with InternalError" {
  match dispatchInvocation(Lambda.newApp(), eventBridgePayload(), testContext()) {
    case Ok(_) -> assertTrue(false, "expected Err when no EventBridge handler is registered")
    case Err(InternalError(msg)) -> {
      assertTrue(msg.contains("EventBridge"), "error names the missing event source")
      assertTrue(msg.contains("eventBridgeHandler"), "error names the Lambda.Direct.eventBridgeHandler factory")
    }
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

// ─── dispatchInvocation: raw ──────────────────────────────────────────────────
record RawOkHandler {
}

impl Lambda.RawHandler for RawOkHandler {
  func handle(payload: in String, ctx: in LambdaContext): Result[Unit, LambdaError] {
    assertEqual(payload, "{\"foo\":\"bar\"}", "raw handler receives the untouched payload text")
    return Ok(value = ())
  }
}

test "dispatchInvocation: raw passes the untouched payload text to the registered RawDirect handler" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.rawHandler(RawOkHandler()))
  match dispatchInvocation(app, "{\"foo\":\"bar\"}", testContext()) {
    case Ok(body) -> assertEqual(body, "null", "raw handler success response body")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

test "dispatchInvocation: raw with no registered handler fails closed with InternalError" {
  match dispatchInvocation(Lambda.newApp(), "{\"foo\":\"bar\"}", testContext()) {
    case Ok(_) -> assertTrue(false, "expected Err when no raw handler is registered")
    case Err(InternalError(msg)) -> assertTrue(msg.contains("raw"), "error names the missing raw handler")
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

// ─── dispatchInvocation: authorizers ──────────────────────────────────────────
record TokenAuthHandler {
}

impl Lambda.TokenAuthorizerHandler for TokenAuthHandler {
  func handle(event: in TokenAuthorizerEvent, ctx: in LambdaContext): Result[AuthorizerResponse, LambdaError] {
    assertEqual(event.authorizationToken, "Bearer xyz", "authorizationToken decoded")
    assertEqual(event.methodArn, "arn:aws:execute-api:us-east-1:123:abc/prod/GET/users", "methodArn decoded")
    return Ok(value = Lambda.Authorizer.allow("user-42", event.methodArn))
  }
}

test "dispatchInvocation: TOKEN authorizer decodes the event and encodes the IAM policy response" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.tokenAuthorizerHandler(TokenAuthHandler()))
  val payload = "{\"type\":\"TOKEN\",\"authorizationToken\":\"Bearer xyz\"," +
    "\"methodArn\":\"arn:aws:execute-api:us-east-1:123:abc/prod/GET/users\"}"
  match dispatchInvocation(app, payload, testContext()) {
    case Ok(body) -> {
      assertTrue(body.contains("\"principalId\":\"user-42\""), "principalId in response")
      assertTrue(body.contains("\"Effect\":\"Allow\""), "IAM policy uses capitalised Effect per AWS convention")
      assertTrue(body.contains("\"Version\":\"2012-10-17\""), "IAM policy Version field present")
    }
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

record RequestAuthHandler {
}

impl Lambda.RequestAuthorizerHandler for RequestAuthHandler {
  func handle(event: in RequestAuthorizerEvent, ctx: in LambdaContext): Result[AuthorizerResponse, LambdaError] {
    assertEqual(event.authorizerType, "REQUEST", "authorizerType decoded from the JSON 'type' field")
    assertEqual(event.requestContext.accountId, "111122223333", "nested requestContext decoded")
    return Ok(value = Lambda.Authorizer.deny("anon", event.methodArn))
  }
}

test "dispatchInvocation: REQUEST authorizer decodes the event including its nested requestContext" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.requestAuthorizerHandler(RequestAuthHandler()))
  val payload = "{\"type\":\"REQUEST\",\"methodArn\":\"arn:x\"," +
    "\"requestContext\":{\"accountId\":\"111122223333\",\"apiId\":\"api1\"}}"
  match dispatchInvocation(app, payload, testContext()) {
    case Ok(body) -> assertTrue(body.contains("\"Effect\":\"Deny\""), "deny effect encoded")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

record HttpAuthHandler {
}

impl Lambda.HttpAuthorizerHandler for HttpAuthHandler {
  func handle(event: in HttpAuthorizerEvent, ctx: in LambdaContext): Result[HttpAuthorizerResponse, LambdaError] {
    assertEqual(event.routeArn, "arn:x", "routeArn decoded")
    assertEqual(event.identitySource, "Bearer xyz", "first identitySource element decoded")
    return Ok(value = Lambda.Authorizer.authorized())
  }
}

test "dispatchInvocation: HTTP API (v2) authorizer decodes the event and encodes isAuthorized" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.httpAuthorizerHandler(HttpAuthHandler()))
  val payload = "{\"version\":\"2.0\",\"type\":\"REQUEST\",\"routeArn\":\"arn:x\",\"identitySource\":[\"Bearer xyz\"]}"
  match dispatchInvocation(app, payload, testContext()) {
    case Ok(body) -> assertEqual(body, "{\"isAuthorized\":true,\"context\":{}}", "HTTP authorizer response JSON")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + Lambda.errorMessage(e))
  }
}

// ─── dispatchInvocation: HTTP (API Gateway / ALB) fails closed ───────────────
test "dispatchInvocation: API Gateway v1 with no router/streaming handler fails closed" {
  val payload = "{\"httpMethod\":\"GET\",\"requestContext\":{\"resourceId\":\"abc\"}}"
  match dispatchInvocation(Lambda.newApp(), payload, testContext()) {
    case Ok(_) -> assertTrue(false, "expected Err: no HTTP handler registered")
    case Err(InternalError(_)) -> ()
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

test "dispatchInvocation: API Gateway v2 with a streaming handler registered still fails closed (not implemented)" {
  val app = Lambda.withStreamingHandler(Lambda.newApp(), "MyApp.Stream.handle")
  val payload = "{\"version\":\"2.0\",\"routeKey\":\"GET /x\",\"requestContext\":{\"http\":{\"method\":\"GET\"}}}"
  match dispatchInvocation(app, payload, testContext()) {
    case Ok(_) -> assertTrue(false, "streaming dispatch is not implemented; must not silently succeed")
    case Err(InternalError(msg)) -> assertTrue(msg.contains("stream") or msg.contains("Stream"), "error names streaming")
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

// ─── lambdaErrorJson: the AWS {"errorMessage","errorType"} shape ─────────────
test "lambdaErrorJson: HandlerError encodes message and errorType verbatim" {
  val err: LambdaError = HandlerError(message = "bad input", errorType = "ValidationError")
  assertEqual(
    lambdaErrorJson(err),
    "{\"errorMessage\":\"bad input\",\"errorType\":\"ValidationError\"}",
    "HandlerError JSON"
  )
}

test "lambdaErrorJson: ParseError uses the ParseError errorType" {
  val err: LambdaError = ParseError(message = "invalid JSON")
  assertEqual(
    lambdaErrorJson(err),
    "{\"errorMessage\":\"invalid JSON\",\"errorType\":\"ParseError\"}",
    "ParseError JSON"
  )
}

test "lambdaErrorJson: InternalError uses the InternalError errorType" {
  val err: LambdaError = InternalError(message = "handler not found")
  assertEqual(
    lambdaErrorJson(err),
    "{\"errorMessage\":\"handler not found\",\"errorType\":\"InternalError\"}",
    "InternalError JSON"
  )
}

test "lambdaErrorJson: TimeoutError includes the remaining time in the message" {
  val err: LambdaError = TimeoutError(remainingMs = 42i64)
  val json = lambdaErrorJson(err)
  assertTrue(json.contains("\"errorType\":\"TimeoutError\""), "TimeoutError errorType")
  assertTrue(json.contains("42"), "remaining ms embedded in errorMessage")
}
