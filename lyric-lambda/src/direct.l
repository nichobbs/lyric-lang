//! Lambda.Direct — AOT-compatible handler registration via typed interfaces.
//!
//! The default registration model (onSqs / onS3 / etc.) identifies handlers
//! by a fully-qualified Lyric function name intended to be resolved at
//! runtime via DLL reflection. That reflection dispatcher was never
//! implemented (no code anywhere in this repository backs it) and later
//! codebase direction rejects the design outright: D099
//! (docs/03-decision-log.md) killed the identical `handlerName: String` +
//! reflection-dispatcher shape for `lyric-health` because contract metadata,
//! source generators, and the Native AOT distribution path all moved away
//! from runtime reflection.
//!
//! `Lambda.Direct` is the sanctioned replacement — the kernel
//! pattern-matches on `DirectHandler`'s case and calls `handler.handle(...)`
//! directly, so the compiler roots the handler at the registration site and
//! no reflection is required at runtime. Each factory below takes an
//! *interface instance* (e.g. `SqsHandler`), not a bare function or closure:
//! docs/03-decision-log.md's "Decision 4 — Handler/Middleware are
//! interfaces, not closures" entry found that a bare named function passed
//! as a function-typed value crashes at runtime the first time it's invoked
//! (#5362), and that invoking any closure across two or more packages
//! compiled into the same program is unreliable on the current self-hosted
//! MSIL backend (#5363) — exactly the shape `Lambda.Direct` needs (consumer
//! handler -> this package's factory -> the kernel's dispatch). Interfaces
//! are the confirmed-safe alternative, already applied to
//! `Web.Handler`/`Web.Middleware` for the identical bug.
//!
//! Usage:
//!
//!   import Lambda.Direct
//!
//!   record HandleQueue {}
//!   impl Lambda.SqsHandler for HandleQueue {
//!     func handle(event: in Lambda.Events.SqsEvent, ctx: in Lambda.LambdaContext): Result[Unit, Lambda.LambdaError] {
//!       // ... process event.records ...
//!       Ok(value = ())
//!     }
//!   }
//!
//!   Lambda.serve(
//!     Lambda.withDirect(Lambda.newApp(), Lambda.Direct.sqsHandler(HandleQueue()))
//!   )
//!
//!
//! Both the interface-based (`Lambda.Direct`) and string-based (`on*`)
//! registration models may coexist in the same LambdaApp — the kernel tries
//! `directHandlers` first; a matching event source with no Direct handler
//! and only a string-based `EventHandler`/`AuthorizerHandler` registration
//! fails closed with `LambdaError.InternalError` rather than silently
//! no-oping (see `Lambda.Dispatch`'s dispatch functions).
//!
//! AOT build: set <PublishAot>true</PublishAot> in the .csproj (or pass
//! --aot to lyric build) and use Lambda.Direct registration exclusively.
//!
//! See docs/35-lambda-library.md §10, decision log D064, D099.
@runtime_checked
@io
package Lambda.Direct

import Std.Core
import Lambda
import Lambda.Events
import Lambda.Authorizer

// ─── Event source handler factories ──────────────────────────────────────────
/// Wrap a SQS handler instance for AOT-safe registration.
/// Return type Unit: entire batch succeeds or fails together.
@stable(since = "0.1")
pub func sqsHandler(h: in SqsHandler): DirectHandler {
  return SqsDirect(handler = h)
}

/// Wrap a SQS handler instance that reports partial-batch failures.
/// Requires the SQS event source mapping to have FunctionResponseTypes =
/// ["ReportBatchItemFailures"].
@stable(since = "0.1")
pub func sqsBatchHandler(h: in SqsBatchHandler): DirectHandler {
  return SqsBatchDirect(handler = h)
}

/// Wrap a SNS handler instance for AOT-safe registration.
@stable(since = "0.1")
pub func snsHandler(h: in SnsHandler): DirectHandler {
  return SnsDirect(handler = h)
}

/// Wrap an S3 handler instance for AOT-safe registration.
@stable(since = "0.1")
pub func s3Handler(h: in S3Handler): DirectHandler {
  return S3Direct(handler = h)
}

/// Wrap an EventBridge handler instance for AOT-safe registration.
@stable(since = "0.1")
pub func eventBridgeHandler(h: in EventBridgeHandler): DirectHandler {
  return EventBridgeDirect(handler = h)
}

/// Wrap a DynamoDB Streams handler instance for AOT-safe registration.
@stable(since = "0.1")
pub func dynamoDbHandler(h: in DynamoDbHandler): DirectHandler {
  return DynamoDbDirect(handler = h)
}

/// Wrap a Kinesis Data Streams handler instance for AOT-safe registration.
@stable(since = "0.1")
pub func kinesisHandler(h: in KinesisHandler): DirectHandler {
  return KinesisDirect(handler = h)
}

/// Wrap a catch-all raw handler instance for AOT-safe registration.
@stable(since = "0.1")
pub func rawHandler(h: in RawHandler): DirectHandler {
  return RawDirect(handler = h)
}

// ─── Authorizer handler factories ─────────────────────────────────────────────
/// Wrap a REST API TOKEN authorizer handler instance for AOT-safe registration.
@stable(since = "0.1")
pub func tokenAuthorizerHandler(h: in TokenAuthorizerHandler): DirectHandler {
  return TokenAuthorizerDirect(handler = h)
}

/// Wrap a REST API REQUEST authorizer handler instance for AOT-safe registration.
@stable(since = "0.1")
pub func requestAuthorizerHandler(h: in RequestAuthorizerHandler): DirectHandler {
  return RequestAuthorizerDirect(handler = h)
}

/// Wrap an HTTP API (v2) authorizer handler instance for AOT-safe registration.
@stable(since = "0.1")
pub func httpAuthorizerHandler(h: in HttpAuthorizerHandler): DirectHandler {
  return HttpAuthorizerDirect(handler = h)
}
