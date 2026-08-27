//! Platform-neutral gRPC client types.
//!
//! Consumers open a GrpcChannel to a server address, make RPC calls passing
//! raw slice[Byte] payloads, and receive raw slice[Byte] responses.
//! The gRPC status code and message are surfaced via GrpcStatus on error.
package Grpc.Types

import Std.Core

// ─── Channel ─────────────────────────────────────────────────────────────────
/// An open gRPC channel to a single server address.
/// Created by Grpc.openChannel; released by Grpc.closeChannel.
/// Channels are safe to share across calls but are not automatically closed.
///
/// Representation: an opaque type's body is only constructible inside its
/// defining package (this one), but the live handle (an `HttpClient` on
/// .NET, something else on JVM) is owned by the platform kernel package —
/// a *different* package. Rather than leak a platform-specific extern type
/// into this neutral package (which would break the other target's build),
/// the kernel keeps the live handle in its own registry keyed by a plain
/// `Int` (the same `HandleCounter`-allocated-id idiom `lyric-ws` /
/// `lyric-jobs` / `lyric-mq` kernels already use), and this type just wraps
/// that key. `wrapChannelHandle` / `channelHandleId` are the "authoring
/// functions" the language reference (docs/01 §2.8) calls for, reachable
/// from `Grpc.Kernel.Net` / `Grpc.Kernel.Jvm` (same project). They are
/// `pub` rather than the more precise `internal` (docs/01 §3.1) because of
/// a compiler bug (#6580) — see their own doc comments.
pub opaque type GrpcChannel {
  handle: Int
}

/// Wrap a platform kernel's registry key as a `GrpcChannel`. Kernel-only —
/// two independent self-hosted-compiler bugs (#6580) force both a specific
/// visibility and a specific call-site spelling here:
///   1. Declared `pub`, not `internal`: a qualified cross-package call to
///      an `internal` function fails to resolve at compile time
///      (`T0020: unknown name`), even though docs/01-language-reference.md
///      §3.1 documents `internal` as cross-package-within-project visible.
///   2. Callers in `Grpc.Kernel.Net` must use qualified syntax
///      (`Types.wrapChannelHandle(id)`), not UFCS (`id.wrapChannelHandle()`):
///      the UFCS form compiles cleanly but fails at *runtime* with
///      `unsupported method 'wrapChannelHandle' ...`, regardless of this
///      function's visibility.
/// Revert to `internal` once #6580 is fixed; UFCS remains a caller-side
/// choice independent of that.
pub func wrapChannelHandle(id: in Int): GrpcChannel {
  GrpcChannel(handle = id)
}

/// Recover the platform kernel's registry key from a `GrpcChannel`.
/// Kernel-only — see `wrapChannelHandle`'s doc comment for why this is
/// `pub` and why callers must use qualified call syntax (#6580).
pub func channelHandleId(ch: in GrpcChannel): Int {
  ch.handle
}

// ─── Status codes ────────────────────────────────────────────────────────────
/// Canonical gRPC status codes (https://grpc.github.io/grpc/core/md_doc_statuscodes.html).
pub enum GrpcStatusCode {
  case Ok
  // 0 — not an error
  case Cancelled
  // 1 — caller cancelled the operation
  case Unknown
  // 2 — unknown error
  case InvalidArgument
  // 3 — client sent an invalid argument
  case DeadlineExceeded
  // 4 — deadline expired before operation completed
  case NotFound
  // 5 — entity not found
  case AlreadyExists
  // 6 — entity already exists
  case PermissionDenied
  // 7 — caller lacks permission
  case ResourceExhausted
  // 8 — resource quota exhausted
  case FailedPrecondition
  // 9 — system not in required state
  case Aborted
  // 10 — operation aborted
  case OutOfRange
  // 11 — operation out of valid range
  case Unimplemented
  // 12 — method not implemented on server
  case Internal
  // 13 — internal invariant violated
  case Unavailable
  // 14 — service currently unavailable
  case DataLoss
  // 15 — unrecoverable data loss or corruption
  case Unauthenticated
  // 16 — caller is not authenticated
}

/// Map an integer gRPC status code to GrpcStatusCode.
pub func statusCodeFromInt(n: Int): GrpcStatusCode {
  match n {
    case 0 -> GrpcStatusCode.Ok
    case 1 -> GrpcStatusCode.Cancelled
    case 2 -> GrpcStatusCode.Unknown
    case 3 -> GrpcStatusCode.InvalidArgument
    case 4 -> GrpcStatusCode.DeadlineExceeded
    case 5 -> GrpcStatusCode.NotFound
    case 6 -> GrpcStatusCode.AlreadyExists
    case 7 -> GrpcStatusCode.PermissionDenied
    case 8 -> GrpcStatusCode.ResourceExhausted
    case 9 -> GrpcStatusCode.FailedPrecondition
    case 10 -> GrpcStatusCode.Aborted
    case 11 -> GrpcStatusCode.OutOfRange
    case 12 -> GrpcStatusCode.Unimplemented
    case 13 -> GrpcStatusCode.Internal
    case 14 -> GrpcStatusCode.Unavailable
    case 15 -> GrpcStatusCode.DataLoss
    case 16 -> GrpcStatusCode.Unauthenticated
    case _ -> GrpcStatusCode.Unknown
  }
}

/// A gRPC call result status (code + human-readable message).
pub record GrpcStatus {
  code: GrpcStatusCode
  message: String
}

/// A metadata key-value pair (sent as gRPC request headers).
pub record GrpcMetadataEntry {
  key: String
  value: String
  // ─── Call options ─────────────────────────────────────────────────────────────
}

/// Per-call options.
pub record GrpcCallOptions {
  timeoutMs: Option[Int]
  metadata: slice[GrpcMetadataEntry]
  // ─── Server-streaming response ────────────────────────────────────────────────
}

/// A lazy sequence of server-streaming response messages.
/// Call nextMessage() repeatedly until it returns None (end of stream) or Err.
pub opaque type GrpcStream

/// A handle to a running gRPC server.
/// Created by Grpc.startHandle; passed to Grpc.stop for graceful shutdown.
/// Same registry-key representation as `GrpcChannel`; see its doc comment.
pub opaque type GrpcServerHandle {
  handle: Int
}

/// Wrap a platform kernel's registry key as a `GrpcServerHandle`. Kernel-only.
internal func wrapServerHandle(id: in Int): GrpcServerHandle {
  GrpcServerHandle(handle = id)
}

/// Recover the platform kernel's registry key from a `GrpcServerHandle`. Kernel-only.
internal func serverHandleId(h: in GrpcServerHandle): Int {
  h.handle
}

// ─── Server routing ───────────────────────────────────────────────────────────
/// Single RPC method registration: proto service name, proto method name,
/// and the qualified Lyric function name the kernel dispatches to.
pub record GrpcRoute {
  service: String
  method: String
  handlerName: String
}

/// Immutable registry of gRPC routes; built with Grpc.addMethod, passed to Grpc.start.
pub record ServiceRegistry {
  routes: slice[GrpcRoute]
}
