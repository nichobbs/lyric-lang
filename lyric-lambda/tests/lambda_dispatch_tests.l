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

// ─── dispatchInvocation: not-yet-implemented sources fail loudly ─────────────
test "dispatchInvocation: aws:sns is detected but dispatch fails closed as not-yet-implemented" {
  match dispatchInvocation(Lambda.newApp(), "{\"Records\":[{\"eventSource\":\"aws:sns\"}]}", testContext()) {
    case Ok(_) -> assertTrue(false, "aws:sns dispatch is not implemented; must not silently succeed")
    case Err(InternalError(msg)) -> assertTrue(msg.contains("aws:sns"), "error names the unimplemented source")
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
  }
}

test "dispatchInvocation: EventBridge is detected but dispatch fails closed as not-yet-implemented" {
  val payload = "{\"source\":\"my.service\",\"detail-type\":\"OrderPlaced\",\"detail\":\"{}\"}"
  match dispatchInvocation(Lambda.newApp(), payload, testContext()) {
    case Ok(_) -> assertTrue(false, "EventBridge dispatch is not implemented; must not silently succeed")
    case Err(InternalError(_)) -> ()
    case Err(other) -> assertTrue(false, "expected InternalError, got: " + Lambda.errorMessage(other))
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
