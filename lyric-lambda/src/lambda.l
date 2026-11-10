//! Lambda — AWS Lambda runtime adapter for Lyric.
//! Stability: @experimental — the live AWS Lambda runtime has not been
//! exercised in CI.  HTTP entry points (API Gateway v1/v2, ALB) and response
//! streaming are not part of this library: see README "Withdrawn surface".
//!
//! Provides the core vocabulary for writing Lambda functions in Lyric and
//! the serve() entry point that drives the Lambda invocation loop.
//!
//! One composition mode:
//!
//!   Custom event source handlers
//!      Register handlers as typed values with `Lambda.Direct.sqsHandler` /
//!      `rawHandler` / the authorizer handlers, then attach them with
//!      `Lambda.withDirect`.  Dispatch is by static value, not name-based
//!      DLL reflection: the reflective `on*` model was rejected (D099) —
//!      bare function references and cross-package closures are unreliable
//!      (#5362/#5363), so handlers are single-method interfaces the
//!      dispatcher invokes directly.  (The signatures below still apply;
//!      only the registration mechanism changed.)
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
@io
package Lambda

import Std.Core
import Std.Iter
import Lambda.Kernel.Runtime as LambdaRuntime
import Lambda.Events
import Lambda.Authorizer

// ─── DirectHandler ───────────────────────────────────────────────────────────
/// One single-method interface per registrable event source / authorizer
/// type. Implement one with a small (usually zero-field) record and
/// register an instance via the matching `Lambda.Direct.*Handler`
/// factory — see `docs/02-worked-examples.md`-style usage in this
/// package's README.
///
/// These are interfaces, not stored closures, for the same reason
/// `Web.Handler`/`Web.Middleware` are (docs/03-decision-log.md's "Decision
/// 4 — Handler/Middleware are interfaces, not closures" entry): a bare
/// named function passed as a function-typed value crashes the first time
/// it's invoked (#5362), and invoking *any* closure — bare or literal —
/// across two or more packages compiled into the same program is
/// unreliable on the current self-hosted MSIL backend, from silent
/// wrong-value corruption to outright crashes (#5363). `DirectHandler`
/// necessarily crosses at least three packages (the consumer's handler,
/// `Lambda.Direct`'s factory, and the kernel's dispatch), so it hits this
/// exactly. Interfaces are `#5363`'s confirmed-safe alternative, verified
/// with the identical repro that found the bug — the same fix already
/// applied to `Web.Handler`/`Web.Middleware`, `WsHandler`, `MailSender`,
/// and `StorageBucket` elsewhere in this codebase.
@stable(since = "0.1")
pub interface SqsHandler {
  func handle(event: in SqsEvent, ctx: in LambdaContext): Result[Unit, LambdaError]
}

@stable(since = "0.1")
pub interface SqsBatchHandler {
  func handle(event: in SqsEvent, ctx: in LambdaContext): Result[SqsBatchResponse, LambdaError]
}

@stable(since = "0.1")
pub interface SnsHandler {
  func handle(event: in SnsEvent, ctx: in LambdaContext): Result[Unit, LambdaError]
}

@stable(since = "0.1")
pub interface S3Handler {
  func handle(event: in S3Event, ctx: in LambdaContext): Result[Unit, LambdaError]
}

@stable(since = "0.1")
pub interface EventBridgeHandler {
  func handle(event: in EventBridgeEvent, ctx: in LambdaContext): Result[Unit, LambdaError]
}

@stable(since = "0.1")
pub interface DynamoDbHandler {
  func handle(event: in DynamoDbEvent, ctx: in LambdaContext): Result[Unit, LambdaError]
}

@stable(since = "0.1")
pub interface KinesisHandler {
  func handle(event: in KinesisEvent, ctx: in LambdaContext): Result[Unit, LambdaError]
}

@stable(since = "0.1")
pub interface RawHandler {
  func handle(payload: in String, ctx: in LambdaContext): Result[Unit, LambdaError]
}

@stable(since = "0.1")
pub interface TokenAuthorizerHandler {
  func handle(event: in TokenAuthorizerEvent, ctx: in LambdaContext): Result[AuthorizerResponse, LambdaError]
}

@stable(since = "0.1")
pub interface RequestAuthorizerHandler {
  func handle(event: in RequestAuthorizerEvent, ctx: in LambdaContext): Result[AuthorizerResponse, LambdaError]
}

@stable(since = "0.1")
pub interface HttpAuthorizerHandler {
  func handle(event: in HttpAuthorizerEvent, ctx: in LambdaContext): Result[HttpAuthorizerResponse, LambdaError]
}

/// An AOT-rooted handler wrapping one of the interfaces above.
/// Created exclusively by the typed factory functions in Lambda.Direct.
/// The kernel pattern-matches on the case and calls `handler.handle(...)`
/// directly — no reflection, no name-based lookup (the DLL-reflection
/// dispatcher this library's doc comments used to describe was never
/// implemented anywhere in the codebase and is rejected by later codebase
/// direction; see D099 in docs/03-decision-log.md, which killed the
/// identical design for `lyric-health`).
///
/// One case per registrable event source / authorizer type.
@stable(since = "0.1")
pub union DirectHandler {
  case SqsDirect(handler: SqsHandler)
  case SqsBatchDirect(handler: SqsBatchHandler)
  case SnsDirect(handler: SnsHandler)
  case S3Direct(handler: S3Handler)
  case EventBridgeDirect(handler: EventBridgeHandler)
  case DynamoDbDirect(handler: DynamoDbHandler)
  case KinesisDirect(handler: KinesisHandler)
  case RawDirect(handler: RawHandler)
  case TokenAuthorizerDirect(handler: TokenAuthorizerHandler)
  case RequestAuthorizerDirect(handler: RequestAuthorizerHandler)
  case HttpAuthorizerDirect(handler: HttpAuthorizerHandler)
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
///
/// DEPRECATED / NON-FUNCTIONAL: the name-based reflective dispatch this
/// record was built for was rejected (D099) and is never invoked by the
/// runtime loop — registering an `EventHandler` has no effect.  Use
/// `Lambda.Direct.*` + `Lambda.withDirect` instead.  Retained only so
/// existing `@stable` signatures still resolve; slated for removal.
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
///
/// DEPRECATED / NON-FUNCTIONAL: like `EventHandler`, the reflective
/// name-based dispatch was rejected (D099) and is never invoked — use
/// `Lambda.Direct.tokenAuthorizerHandler` / `requestAuthorizerHandler` /
/// `httpAuthorizerHandler` + `Lambda.withDirect` instead.
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
/// Build one with newApp(), then attach event and authorizer handlers.
/// The kernel routes authorizer invocations to the
/// authorizer handler table, and all other events to the event handler table.
/// AOT-safe direct handlers are resolved from directHandlers first; string-
/// based handlers are the fallback for non-AOT builds.
@stable(since = "0.1")
pub record LambdaApp {
  eventHandlers: slice[EventHandler]
  authorizerHandlers: slice[AuthorizerHandler]
  directHandlers: slice[DirectHandler]  // AOT-safe function-reference handlers
}

/// Empty application.
@stable(since = "0.1")
pub func newApp(): LambdaApp {
  return LambdaApp(eventHandlers = [], authorizerHandlers = [], directHandlers = [])
}

/// Register an AOT-compatible direct handler created with Lambda.Direct.*Handler().
/// Replaces the string-based on*() registration for Native AOT builds.
@stable(since = "0.1")
pub func withDirect(app: in LambdaApp, handler: in DirectHandler): LambdaApp {
  return LambdaApp(
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
///   Dispatches each event to the matching registered handler.
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
