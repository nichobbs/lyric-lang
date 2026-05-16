/// Platform-neutral gRPC client types.
///
/// Consumers open a GrpcChannel to a server address, make RPC calls passing
/// raw slice[Byte] payloads, and receive raw slice[Byte] responses.
/// The gRPC status code and message are surfaced via GrpcStatus on error.
package Grpc.Types

import Std.Core

// ─── Channel ─────────────────────────────────────────────────────────────────

/// An open gRPC channel to a single server address.
/// Created by Grpc.openChannel; released by Grpc.closeChannel.
/// Channels are safe to share across calls but are not automatically closed.
pub opaque type GrpcChannel

// ─── Status codes ────────────────────────────────────────────────────────────

/// Canonical gRPC status codes (https://grpc.github.io/grpc/core/md_doc_statuscodes.html).
pub type GrpcStatusCode = enum {
  case Ok                 // 0 — not an error
  case Cancelled          // 1 — caller cancelled the operation
  case Unknown            // 2 — unknown error
  case InvalidArgument    // 3 — client sent an invalid argument
  case DeadlineExceeded   // 4 — deadline expired before operation completed
  case NotFound           // 5 — entity not found
  case AlreadyExists      // 6 — entity already exists
  case PermissionDenied   // 7 — caller lacks permission
  case ResourceExhausted  // 8 — resource quota exhausted
  case FailedPrecondition // 9 — system not in required state
  case Aborted            // 10 — operation aborted
  case OutOfRange         // 11 — operation out of valid range
  case Unimplemented      // 12 — method not implemented on server
  case Internal           // 13 — internal invariant violated
  case Unavailable        // 14 — service currently unavailable
  case DataLoss           // 15 — unrecoverable data loss or corruption
  case Unauthenticated    // 16 — caller is not authenticated
}

/// Map an integer gRPC status code to GrpcStatusCode.
pub func statusCodeFromInt(n: Int): GrpcStatusCode {
  match n {
    case 0  -> GrpcStatusCode.Ok
    case 1  -> GrpcStatusCode.Cancelled
    case 2  -> GrpcStatusCode.Unknown
    case 3  -> GrpcStatusCode.InvalidArgument
    case 4  -> GrpcStatusCode.DeadlineExceeded
    case 5  -> GrpcStatusCode.NotFound
    case 6  -> GrpcStatusCode.AlreadyExists
    case 7  -> GrpcStatusCode.PermissionDenied
    case 8  -> GrpcStatusCode.ResourceExhausted
    case 9  -> GrpcStatusCode.FailedPrecondition
    case 10 -> GrpcStatusCode.Aborted
    case 11 -> GrpcStatusCode.OutOfRange
    case 12 -> GrpcStatusCode.Unimplemented
    case 13 -> GrpcStatusCode.Internal
    case 14 -> GrpcStatusCode.Unavailable
    case 15 -> GrpcStatusCode.DataLoss
    case 16 -> GrpcStatusCode.Unauthenticated
    case _  -> GrpcStatusCode.Unknown
  }
}

/// A gRPC call result status (code + human-readable message).
pub type GrpcStatus = record {
  code:    GrpcStatusCode
  message: String
}

/// A metadata key-value pair (sent as gRPC request headers).
pub type GrpcMetadataEntry = record {
  key:   String
  value: String
}

// ─── Call options ─────────────────────────────────────────────────────────────

/// Per-call options.
pub type GrpcCallOptions = record {
  /// Optional call deadline in milliseconds from now.
  /// None means no deadline (inherits channel default, if any).
  timeoutMs: Option[Int]
  /// Extra gRPC metadata (request headers) to attach to this call.
  metadata:  List[GrpcMetadataEntry]
}

// ─── Server-streaming response ────────────────────────────────────────────────

/// A lazy sequence of server-streaming response messages.
/// Call nextMessage() repeatedly until it returns None (end of stream) or Err.
pub opaque type GrpcStream

// ─── Server routing ───────────────────────────────────────────────────────────

/// Single RPC method registration: proto service name, proto method name,
/// and the qualified Lyric function name the kernel dispatches to.
pub record GrpcRoute {
  service:     String
  method:      String
  handlerName: String
}

/// Immutable registry of gRPC routes; built with Grpc.addMethod, passed to Grpc.start.
pub record ServiceRegistry {
  routes: [GrpcRoute]
}
