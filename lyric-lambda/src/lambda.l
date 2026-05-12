/// Lambda — AWS Lambda runtime adapter for Lyric.
///
/// Provides the core vocabulary for writing Lambda functions in Lyric and
/// the serve() entry point that drives the Lambda invocation loop.
///
/// Two composition modes (may be combined in the same LambdaApp):
///
///   1. lyric-web router reuse
///      Build a Web.Router exactly as you would for a Kestrel service, then
///      attach it with withRouter().  API Gateway v1 (REST API), v2 (HTTP API),
///      and ALB events are all routed through the same Web.Route dispatch
///      logic — the same handler functions work unchanged.
///
///      Example:
///        val router = Web.create()
///          |> Web.addGet("/users/{id}", "MyApp.Users.getUser")
///          |> Web.addPost("/users",     "MyApp.Users.createUser")
///        Lambda.serve(Lambda.newApp() |> Lambda.withRouter(router))
///
///   2. Custom event source handlers
///      Register handlers by fully-qualified function name with the
///      onSqs / onSns / onS3 / onEventBridge / onDynamoDb / onRaw helpers.
///      The kernel resolves each handler via DLL reflection at startup and
///      invokes it with the deserialised event and LambdaContext.
///
///      Handler signatures:
///        SQS:         func h(event: Lambda.Events.SqsEvent,         ctx: Lambda.LambdaContext): Result[R, Lambda.LambdaError]
///        SNS:         func h(event: Lambda.Events.SnsEvent,         ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
///        S3:          func h(event: Lambda.Events.S3Event,          ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
///        EventBridge: func h(event: Lambda.Events.EventBridgeEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
///        DynamoDB:    func h(event: Lambda.Events.DynamoDbEvent,    ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
///        Raw:         func h(payload: String,                       ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
///
///      where R for SQS may be Unit or Lambda.Events.SqsBatchResponse for
///      partial-batch-failure reporting.
///
/// Runtime env vars:
///   AWS_LAMBDA_RUNTIME_API                  — injected by Lambda; drives the custom runtime loop
///   LYRIC_CONFIG_LAMBDA_RUNTIME_LOCALPORT   — local test server port (feature="local"; default: 9000)
///
/// See docs/35-lambda-library.md, decision log D062.

@runtime_checked
package Lambda

import Std.Core
import Web
import Lambda.Kernel.Runtime as LambdaRuntime

// ─── LambdaContext ────────────────────────────────────────────────────────────

/// Invocation context injected by the Lambda runtime.
/// Available to all handlers registered via onSqs / onSns / etc.
/// API Gateway handlers receive it as an aspect or via DeadlineGuard.
@stable(since="0.1")
pub record LambdaContext {
  functionName:       String
  functionVersion:    String
  invokedFunctionArn: String
  memoryLimitInMb:    Int
  requestId:          String
  logGroupName:       String
  logStreamName:      String
  /// Milliseconds until the Lambda timeout deadline; decreasing monotonically.
  /// Check this in long-running handlers; use the DeadlineGuard aspect for
  /// automatic bail-out before the deadline is reached.
  remainingTimeMs:    Long
}

// ─── LambdaError ─────────────────────────────────────────────────────────────

/// Typed error union for Lambda handler failures.
@stable(since="0.1")
pub union LambdaError {
  /// The handler returned an application-level error.
  case HandlerError(message: String, errorType: String)
  /// The kernel could not deserialise the event payload into the expected type.
  case ParseError(message: String)
  /// The handler was not invoked because the deadline was too close.
  /// remainingMs carries the time left at the point the guard fired.
  case TimeoutError(remainingMs: Long)
  /// An unexpected runtime failure (DLL reflection miss, unhandled exception, etc.).
  case InternalError(message: String)
}

/// Human-readable message for logging or diagnostic output.
@stable(since="0.1")
pub func errorMessage(err: in LambdaError): String {
  match err {
    HandlerError(msg, t) => return t + ": " + msg
    ParseError(msg)      => return "ParseError: " + msg
    TimeoutError(ms)     => return "TimeoutError: " + ms.toString() + "ms remaining"
    InternalError(msg)   => return "InternalError: " + msg
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
///   "aws.events"   — EventBridge / CW Events   (Lambda.Events.EventBridgeEvent)
///   "raw"          — catch-all for unknown events (String payload)
@stable(since="0.1")
pub record EventHandler {
  eventSource: String
  handlerName: String
}

// ─── LambdaApp ────────────────────────────────────────────────────────────────

/// Immutable Lambda application definition.
/// Build one with newApp(), then attach a router and/or event handlers.
/// Both modes may coexist in the same LambdaApp: the kernel routes
/// HTTP events to the router and all other events to the registered handlers.
@stable(since="0.1")
pub record LambdaApp {
  httpRouter:    Option[Web.Router]
  eventHandlers: [EventHandler]
}

/// Empty application with no router and no custom event handlers.
@stable(since="0.1")
pub func newApp(): LambdaApp {
  return LambdaApp(httpRouter = None, eventHandlers = [])
}

/// Attach a lyric-web Router for API Gateway and ALB HTTP events.
/// API Gateway v1 (REST API), v2 (HTTP API), and ALB events are mapped
/// to the router's method + path and dispatched through the same mechanism
/// as Web.start().  CORS config is read from the Web.Cors config block.
@stable(since="0.1")
pub func withRouter(app: in LambdaApp, router: in Web.Router): LambdaApp {
  return LambdaApp(httpRouter = Some(router), eventHandlers = app.eventHandlers)
}

// Private helper — adds an EventHandler to the app.
func addHandler(app: in LambdaApp, src: in String, name: in String): LambdaApp
  requires: src.length > 0
  requires: name.length > 0
{
  val h = EventHandler(eventSource = src, handlerName = name)
  return LambdaApp(httpRouter = app.httpRouter, eventHandlers = app.eventHandlers + [h])
}

/// Register a handler for SQS events.
/// Handler type:
///   func h(event: Lambda.Events.SqsEvent, ctx: Lambda.LambdaContext): Result[R, Lambda.LambdaError]
/// R may be Unit or Lambda.Events.SqsBatchResponse (partial-batch-failure mode).
/// Partial-batch mode requires the SQS event source mapping to have
/// FunctionResponseTypes = ["ReportBatchItemFailures"].
@stable(since="0.1")
pub func onSqs(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws:sqs", handlerName)
}

/// Register a handler for SNS notification events.
/// Handler type:
///   func h(event: Lambda.Events.SnsEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
@stable(since="0.1")
pub func onSns(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws:sns", handlerName)
}

/// Register a handler for S3 object events.
/// Handler type:
///   func h(event: Lambda.Events.S3Event, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
@stable(since="0.1")
pub func onS3(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws:s3", handlerName)
}

/// Register a handler for EventBridge (and CloudWatch Events) events.
/// Handler type:
///   func h(event: Lambda.Events.EventBridgeEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
@stable(since="0.1")
pub func onEventBridge(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws.events", handlerName)
}

/// Register a handler for DynamoDB Streams events.
/// Handler type:
///   func h(event: Lambda.Events.DynamoDbEvent, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
@stable(since="0.1")
pub func onDynamoDb(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "aws:dynamodb", handlerName)
}

/// Register a catch-all handler for unrecognised event JSON.
/// Handler type:
///   func h(payload: String, ctx: Lambda.LambdaContext): Result[Unit, Lambda.LambdaError]
/// Use this for event sources not covered by the typed registrations above.
@stable(since="0.1")
pub func onRaw(app: in LambdaApp, handlerName: in String): LambdaApp
  requires: handlerName.length > 0
{
  return addHandler(app, "raw", handlerName)
}

// ─── Runtime config ───────────────────────────────────────────────────────────

/// Runtime configuration read once at startup.
/// In production (feature="aws") localPort is unused.
/// In local mode (feature="local") localPort is the port for the test server.
config Runtime {
  localPort: Int range 1..=65535 = 9000
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
@stable(since="0.1")
pub func serve(app: in LambdaApp): Unit {
  LambdaRuntime.serve(app, Runtime.localPort)
}
