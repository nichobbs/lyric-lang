//! Lambda — AWS Lambda runtime adapter for Lyric.
//! Stability: @experimental — the API Gateway v1/v2/ALB bridges compile and
//! unit tests cover the request-shape adapters, but the live AWS Lambda
//! runtime has not been exercised in CI.
//!
//! Provides the core vocabulary for writing Lambda functions in Lyric and
//! the serve() entry point that drives the Lambda invocation loop.
//!
//! Two composition modes (may be combined in the same LambdaApp):
//!
//!   1. lyric-web router reuse
//!      Build a Web.Router exactly as you would for a Kestrel service, then
//!      attach it with withRouter().  API Gateway v1 (REST API), v2 (HTTP API),
//!      and ALB events are all routed through the same Web.Route dispatch
//!      logic — the same handler functions work unchanged.
//!
//!      Example:
//!        val router = Web.create()
//!          |> Web.addGet("/users/{id}", "MyApp.Users.getUser")
//!          |> Web.addPost("/users",     "MyApp.Users.createUser")
//!        Lambda.serve(Lambda.newApp() |> Lambda.withRouter(router))
//!
//!   2. Custom event source handlers
//!      Register handlers by fully-qualified function name with the
//!      onSqs / onSns / onS3 / onEventBridge / onDynamoDb / onRaw helpers.
//!      The kernel resolves each handler via DLL reflection at startup and
//!      invokes it with the deserialised event and LambdaContext.
//!
//!      Handler signatures:
//!        SQS:         func h(event: Lambda.Events.SqsEvent,         ctx: Lambda.LambdaContext): Result[R, Lambda.LambdaError]
//!        SNS:         func h(event: Lambda.Events.SnsEvent,         ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
//!        S3:          func h(event: Lambda.Events.S3Event,          ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
//!        EventBridge: func h(event: Lambda.Events.EventBridgeEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
//!        DynamoDB:    func h(event: Lambda.Events.DynamoDbEvent,    ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
//!        Raw:         func h(payload: String,                       ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
//!
//!      where R for SQS may be Unit or Lambda.Events.SqsBatchResponse for
//!      partial-batch-failure reporting.
//!
//! Runtime env vars:
//!   AWS_LAMBDA_RUNTIME_API                  — injected by Lambda; drives the custom runtime loop
//!   LYRIC_CONFIG_LAMBDA_RUNTIME_LOCALPORT   — local test server port (feature="local"; default: 9000)
//!
//! See docs/35-lambda-library.md, decision log D062.
@runtime_checked
package Lambda

import Std.Core
import Std.Iter
import Lambda.Kernel.Runtime as LambdaRuntime

// ─── DirectHandler ───────────────────────────────────────────────────────────
/// An AOT-rooted handler wrapping a function reference.
/// Created exclusively by the typed factory functions in Lambda.Direct.
/// The kernel holds the delegate directly without reflection.
@stable(since = "0.1")
pub opaque type DirectHandler {
  // kernel-held delegate; eventSource key for dispatch
}

// ─── LambdaRouter ────────────────────────────────────────────────────────────
/// Opaque token representing a Web.Router registered with a LambdaApp.
/// Created exclusively by Lambda.withRouter() (requires the `web` feature).
/// The Lambda kernel resolves the actual Router via an internal registry keyed
/// by this token's CLR identity; no Web types appear in LambdaApp's contract
/// metadata, so consumers without lyric-web compile successfully.
@stable(since = "0.1")
pub opaque type LambdaRouter {
  // kernel-held Web.Router reference managed by Lambda.Kernel.Net via
  // ConditionalWeakTable<LambdaRouter, Router>; zero visible Lyric fields.
}

// ─── LambdaContext ────────────────────────────────────────────────────────────
/// Invocation context injected by the Lambda runtime.
/// Available to all handlers registered via onSqs / onSns / etc.
/// API Gateway handlers receive it as an aspect or via DeadlineGuard.
@stable(since = "0.1")
pub record LambdaContext {
  functionName: String
  functionVersion: String
  invokedFunctionArn: String
  memoryLimitInMb: Int
  requestId: String
  logGroupName: String
  logStreamName: String
  /// Milliseconds until the Lambda timeout deadline; decreasing monotonically.
  /// Check this in long-running handlers; use the DeadlineGuard aspect for
  /// automatic bail-out before the deadline is reached.
  remainingTimeMs: Long
}

// ─── LambdaError ─────────────────────────────────────────────────────────────
/// Typed error union for Lambda handler failures.
@stable(since = "0.1")
pub union LambdaError {
  case HandlerError(message: String, errorType: String)
  case ParseError(message: String)
  case TimeoutError(remainingMs: Long)
  case InternalError(message: String)
}

/// Human-readable message for logging or diagnostic output.
@stable(since = "0.1")
pub func errorMessage(err: in LambdaError): String {
  match err {
    case HandlerError(msg, t) -> return t + ": " + msg
    case ParseError(msg) -> return "ParseError: " + msg
    case TimeoutError(ms) -> return "TimeoutError: " + ms.toString() + "ms remaining"
    case InternalError(msg) -> return "InternalError: " + msg
  }
}

// ─── EventHandler ─────────────────────────────────────────────────────────────
/// Binds an event-source key to a Lyric handler function by qualified name.
/// The kernel resolves handlerName via DLL reflection at startup.
///
/// Standard event-source keys (matched against the raw JSON payload by the kernel):
///   "aws:sqs"      — SQS record batch         (Lambda.Events.SqsEvent)
///   "aws:sns"      — SNS notification batch    (Lambda.Events.SnsEvent)
///   "aws:s3"       — S3 object event batch     (Lambda.Events.S3Event)
///   "aws:dynamodb" — DynamoDB stream records   (Lambda.Events.DynamoDbEvent)
///   "aws:kinesis"  — Kinesis stream records    (Lambda.Events.KinesisEvent)
///   "aws.events"   — EventBridge / CW Events   (Lambda.Events.EventBridgeEvent)
///   "raw"          — catch-all for unknown events (String payload)
@stable(since = "0.1")
pub record EventHandler {
  eventSource: String
  handlerName: String
}

// ─── AuthorizerHandler ────────────────────────────────────────────────────────
/// Binds an authorizer type to a Lyric handler function by qualified name.
/// The kernel resolves handlerName via DLL reflection at startup.
///
/// authorizerType values:
///   "token"   — REST API TOKEN authorizer  (Lambda.Authorizer.TokenAuthorizerEvent)
///   "request" — REST API REQUEST authorizer (Lambda.Authorizer.RequestAuthorizerEvent)
///   "http"    — HTTP API (v2) authorizer   (Lambda.Authorizer.HttpAuthorizerEvent)
@stable(since = "0.1")
pub record AuthorizerHandler {
  authorizerType: String
  handlerName: String
}

// ─── LambdaApp ────────────────────────────────────────────────────────────────
/// Immutable Lambda application definition.
/// Build one with newApp(), then attach a router and/or event handlers.
/// All modes may coexist in a single LambdaApp: the kernel routes HTTP events
/// to the router (or streaming handler), authorizer invocations to the
/// authorizer handler table, and all other events to the event handler table.
/// AOT-safe direct handlers are resolved from directHandlers first; string-
/// based handlers are the fallback for non-AOT builds.
@stable(since = "0.1")
pub record LambdaApp {
  httpRouter: Option[LambdaRouter]
  streamingHandler: Option[String]           // qualified name of a streaming HTTP handler
  eventHandlers: slice[EventHandler]
  authorizerHandlers: slice[AuthorizerHandler]
  directHandlers: slice[DirectHandler]  // AOT-safe function-reference handlers
}

/// Empty application.
@stable(since = "0.1")
pub func newApp(): LambdaApp {
  return LambdaApp(
    httpRouter = None,
    streamingHandler = None,
    eventHandlers = [],
    authorizerHandlers = [],
    directHandlers = []
  )
}

/// Attach a streaming HTTP handler for Lambda Function URL or HTTP API streaming.
/// All HTTP traffic is forwarded to this handler; Web.Router is not consulted.
/// Handler signature:
///   func h(rawEvent: String, ctx: Lambda.LambdaContext, writer: Lambda.Stream.StreamWriter): Result[Unit, Lambda.LambdaError]
/// Cannot be combined with withRouter in the same LambdaApp.
/// For AOT builds use Lambda.Direct.streamingHandler + withDirect instead.
@stable(since = "0.1")
pub func withStreamingHandler(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return LambdaApp(
    httpRouter = app.httpRouter,
    streamingHandler = Some(handlerName),
    eventHandlers = app.eventHandlers,
    authorizerHandlers = app.authorizerHandlers,
    directHandlers = app.directHandlers
  )
}

/// Register an AOT-compatible direct handler created with Lambda.Direct.*Handler().
/// Replaces the string-based on*() registration for Native AOT builds.
@stable(since = "0.1")
pub func withDirect(app: in LambdaApp, handler: in DirectHandler): LambdaApp {
  return LambdaApp(
    httpRouter = app.httpRouter,
    streamingHandler = app.streamingHandler,
    eventHandlers = app.eventHandlers,
    authorizerHandlers = app.authorizerHandlers,
    directHandlers = concat(app.directHandlers, [handler])
  )
}

// Private helper — adds an EventHandler to the app.
func addHandler(app: in LambdaApp, src: in String, name: in String): LambdaApp
  requires: src.length > 0
  requires: name.length > 0
{
  val h = EventHandler(eventSource = src, handlerName = name)
  return LambdaApp(
    httpRouter = app.httpRouter,
    streamingHandler = app.streamingHandler,
    eventHandlers = concat(app.eventHandlers, [h]),
    authorizerHandlers = app.authorizerHandlers,
    directHandlers = app.directHandlers
  )
}

// Private helper — adds an AuthorizerHandler to the app.
func addAuthorizerHandler(app: in LambdaApp, authType: in String, name: in String): LambdaApp
  requires: authType.length > 0
  requires: name.length > 0
{
  val h = AuthorizerHandler(authorizerType = authType, handlerName = name)
  return LambdaApp(
    httpRouter = app.httpRouter,
    streamingHandler = app.streamingHandler,
    eventHandlers = app.eventHandlers,
    authorizerHandlers = concat(app.authorizerHandlers, [h]),
    directHandlers = app.directHandlers
  )
}

/// Register a handler for SQS events.
/// Handler type:
///   func h(event: Lambda.Events.SqsEvent, ctx: Lambda.LambdaContext): Result[R, Lambda.LambdaError]
/// R may be Unit or Lambda.Events.SqsBatchResponse (partial-batch-failure mode).
/// Partial-batch mode requires the SQS event source mapping to have
/// FunctionResponseTypes = ["ReportBatchItemFailures"].
@stable(since = "0.1")
pub func onSqs(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws:sqs", handlerName)
}

/// Register a handler for SNS notification events.
/// Handler type:
///   func h(event: Lambda.Events.SnsEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
@stable(since = "0.1")
pub func onSns(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws:sns", handlerName)
}

/// Register a handler for S3 object events.
/// Handler type:
///   func h(event: Lambda.Events.S3Event, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
@stable(since = "0.1")
pub func onS3(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws:s3", handlerName)
}

/// Register a handler for EventBridge (and CloudWatch Events) events.
/// Handler type:
///   func h(event: Lambda.Events.EventBridgeEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
@stable(since = "0.1")
pub func onEventBridge(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws.events", handlerName)
}

/// Register a handler for DynamoDB Streams events.
/// Handler type:
///   func h(event: Lambda.Events.DynamoDbEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
@stable(since = "0.1")
pub func onDynamoDb(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws:dynamodb", handlerName)
}

/// Register a handler for Kinesis Data Streams events.
/// Handler type:
///   func h(event: Lambda.Events.KinesisEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
@stable(since = "0.1")
pub func onKinesis(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws:kinesis", handlerName)
}

/// Register a catch-all handler for unrecognised event JSON.
/// Handler type:
///   func h(payload: String, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
/// Use this for event sources not covered by the typed registrations above.
@stable(since = "0.1")
pub func onRaw(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "raw", handlerName)
}

// ─── Authorizer registration ──────────────────────────────────────────────────
/// Register a REST API TOKEN Lambda authorizer handler.
/// The Lambda function receives a TokenAuthorizerEvent and must return an
/// IAM policy document.
///
/// Handler type:
///   func h(event: Lambda.Authorizer.TokenAuthorizerEvent, ctx: Lambda.LambdaContext): Result[Lambda.Authorizer.AuthorizerResponse, Lambda.LambdaError]
///
/// Configure the authorizer in API Gateway as type TOKEN with the Lambda
/// function ARN.  The identity source is typically $request.header.Authorization.
@stable(since = "0.1")
pub func onTokenAuthorizer(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addAuthorizerHandler(app, "token", handlerName)
}

/// Register a REST API REQUEST Lambda authorizer handler.
/// The Lambda function receives the full request context and must return an
/// IAM policy document.
///
/// Handler type:
///   func h(event: Lambda.Authorizer.RequestAuthorizerEvent, ctx: Lambda.LambdaContext): Result[Lambda.Authorizer.AuthorizerResponse, Lambda.LambdaError]
///
/// Configure the authorizer in API Gateway as type REQUEST.  The identity
/// source may reference any combination of headers, query parameters, stage
/// variables, and context variables.
@stable(since = "0.1")
pub func onRequestAuthorizer(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addAuthorizerHandler(app, "request", handlerName)
}

/// Register an HTTP API (v2) Lambda authorizer handler.
/// The Lambda function receives a lightweight request context and returns
/// a simple { isAuthorized, context } response — no IAM policy needed.
///
/// Handler type:
///   func h(event: Lambda.Authorizer.HttpAuthorizerEvent, ctx: Lambda.LambdaContext): Result[Lambda.Authorizer.HttpAuthorizerResponse, Lambda.LambdaError]
///
/// Configure the authorizer in API Gateway as a Lambda authorizer on an HTTP
/// API route.  The payload format version must be 2.0.
@stable(since = "0.1")
pub func onHttpAuthorizer(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addAuthorizerHandler(app, "http", handlerName)
}

// ─── Runtime config ───────────────────────────────────────────────────────────
/// Runtime configuration read once at startup.
/// In production (feature="aws") localPort is unused.
/// In local mode (feature="local") localPort is the port for the test server.
config Runtime {
  localPort: Int = 9000
}

// ─── Entry point ──────────────────────────────────────────────────────────────
/// Start the Lambda invocation loop.
///
/// In production (feature="aws"):
///   Polls the Lambda Runtime API for events indefinitely.
///   Dispatches each event to either the httpRouter (API Gateway / ALB) or
///   the matching registered EventHandler.
///   Posts the response or error back to the runtime API.
///   Blocks until the Lambda execution environment terminates the process.
///
/// In local mode (feature="local"):
///   Listens at localhost:Runtime.localPort for
///   POST /2015-03-31/functions/function/invocations requests.
///   Body: raw Lambda event JSON (identical to the Lambda console test-event format).
///   Response: the Lambda response JSON.
///   Compatible with `aws lambda invoke` and `sam local invoke`.
@stable(since = "0.1")
@cfg(feature = "aws")
pub func serve(app: in LambdaApp): Unit {
  LambdaRuntime.serve(app, Runtime.localPort)
}

@stable(since = "0.1")
@cfg(feature = "local")
pub func serve(app: in LambdaApp): Unit {
  LambdaRuntime.serve(app, Runtime.localPort)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func serve(app: in LambdaApp): Unit {
  LambdaRuntime.serve(app, Runtime.localPort)
}
