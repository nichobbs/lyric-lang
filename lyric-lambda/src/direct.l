// Lambda.Direct — AOT-compatible handler registration via function references.
//
// The default registration model (onSqs / onS3 / etc.) identifies handlers
// by a fully-qualified Lyric function name resolved at runtime via DLL
// reflection.  This is incompatible with Native AOT (`PublishAot=true`)
// because the AOT linker trims unreferenced methods.
//
// Lambda.Direct provides a parallel registration path that accepts a
// function reference directly.  The linker can see the reference at compile
// time and roots the method, so no reflection is required at runtime.
//
// Usage:
//
//   import Lambda.Direct
//
//   Lambda.serve(
//     Lambda.newApp()
//       |> Lambda.withDirect(Lambda.Direct.sqsHandler(MyApp.Queue.handleBatch))
//       |> Lambda.withDirect(Lambda.Direct.s3Handler(MyApp.Store.handleObject)))
//
//   // For API Gateway HTTP traffic, use withDirectRouter (see Lambda package).
//
// Handler signatures are identical to the reflection-based model; only the
// registration call differs.  Both models may coexist in the same LambdaApp.
//
// AOT build: set <PublishAot>true</PublishAot> in the .csproj (or pass
// --aot to lyric build) and use Lambda.Direct registration exclusively.
// String-based registrations (onSqs / onS3 / etc.) emit a build warning
// when PublishAot is detected.
//
// See docs/35-lambda-library.md §10, decision log D064.

@runtime_checked
package Lambda.Direct

import Std.Core
import Web
import Lambda
import Lambda.Events
import Lambda.Authorizer
import Lambda.Stream

// ─── Event source handler factories ──────────────────────────────────────────

/// Wrap a SQS handler function reference for AOT-safe registration.
/// Return type Unit: entire batch succeeds or fails together.
@stable(since="0.1")
pub func sqsHandler(
  h: in (SqsEvent, LambdaContext) -> Result[Unit, LambdaError]
): DirectHandler

/// Wrap a SQS handler that reports partial-batch failures.
/// Requires the SQS event source mapping to have FunctionResponseTypes =
/// ["ReportBatchItemFailures"].
@stable(since="0.1")
pub func sqsBatchHandler(
  h: in (SqsEvent, LambdaContext) -> Result[SqsBatchResponse, LambdaError]
): DirectHandler

/// Wrap a SNS handler function reference for AOT-safe registration.
@stable(since="0.1")
pub func snsHandler(
  h: in (SnsEvent, LambdaContext) -> Result[Unit, LambdaError]
): DirectHandler

/// Wrap an S3 handler function reference for AOT-safe registration.
@stable(since="0.1")
pub func s3Handler(
  h: in (S3Event, LambdaContext) -> Result[Unit, LambdaError]
): DirectHandler

/// Wrap an EventBridge handler function reference for AOT-safe registration.
@stable(since="0.1")
pub func eventBridgeHandler(
  h: in (EventBridgeEvent, LambdaContext) -> Result[Unit, LambdaError]
): DirectHandler

/// Wrap a DynamoDB Streams handler function reference for AOT-safe registration.
@stable(since="0.1")
pub func dynamoDbHandler(
  h: in (DynamoDbEvent, LambdaContext) -> Result[Unit, LambdaError]
): DirectHandler

/// Wrap a Kinesis Data Streams handler function reference for AOT-safe registration.
@stable(since="0.1")
pub func kinesisHandler(
  h: in (KinesisEvent, LambdaContext) -> Result[Unit, LambdaError]
): DirectHandler

/// Wrap a catch-all raw handler function reference for AOT-safe registration.
@stable(since="0.1")
pub func rawHandler(
  h: in (String, LambdaContext) -> Result[Unit, LambdaError]
): DirectHandler

// ─── Authorizer handler factories ─────────────────────────────────────────────

/// Wrap a REST API TOKEN authorizer function reference for AOT-safe registration.
@stable(since="0.1")
pub func tokenAuthorizerHandler(
  h: in (TokenAuthorizerEvent, LambdaContext) -> Result[AuthorizerResponse, LambdaError]
): DirectHandler

/// Wrap a REST API REQUEST authorizer function reference for AOT-safe registration.
@stable(since="0.1")
pub func requestAuthorizerHandler(
  h: in (RequestAuthorizerEvent, LambdaContext) -> Result[AuthorizerResponse, LambdaError]
): DirectHandler

/// Wrap an HTTP API (v2) authorizer function reference for AOT-safe registration.
@stable(since="0.1")
pub func httpAuthorizerHandler(
  h: in (HttpAuthorizerEvent, LambdaContext) -> Result[HttpAuthorizerResponse, LambdaError]
): DirectHandler

// ─── Streaming handler factory ────────────────────────────────────────────────

/// Wrap a streaming HTTP handler for AOT-safe registration.
/// The handler receives the raw API Gateway v2 event JSON and a StreamWriter;
/// it writes response chunks and returns when done.
/// Equivalent to Lambda.withStreamingHandler() but AOT-safe.
@stable(since="0.1")
pub func streamingHandler(
  h: in (String, LambdaContext, StreamWriter) -> Result[Unit, LambdaError]
): DirectHandler
