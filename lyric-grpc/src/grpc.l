/// Lyric gRPC client library — platform-dispatch wrappers.
///
/// Provides a general-purpose gRPC client that accepts and returns raw
/// slice[Byte] payloads.  Callers are responsible for encoding request messages
/// and decoding responses; use lyric-proto for protobuf serialisation.
///
/// Channel lifecycle:
///   val ch = Grpc.openChannel("https://collector:4317").unwrap()
///   // … make calls …
///   Grpc.closeChannel(ch)   // releases HTTP/2 connections
///
/// The channel is safe to share across concurrent calls.  Channels are not
/// automatically closed; always close explicitly before process exit or the
/// connection pool may leak.
package Grpc

import Grpc.Types
import Grpc.Kernel.Net
import Grpc.Kernel.Jvm
import Std.Core
import Std.Collections

// ─── Default options ──────────────────────────────────────────────────────────

/// Default call options: no deadline, no metadata.
pub func defaultOptions(): GrpcCallOptions {
  GrpcCallOptions {
    timeoutMs = Option.None
    metadata  = List.empty()
  }
}

/// Return options with a specific deadline (milliseconds from now).
pub func withTimeout(opts: GrpcCallOptions, ms: Int): GrpcCallOptions {
  GrpcCallOptions { timeoutMs = Option.Some(ms), metadata = opts.metadata }
}

/// Return options with an extra metadata entry added.
pub func withMetadata(opts: GrpcCallOptions, key: String, value: String): GrpcCallOptions {
  GrpcCallOptions {
    timeoutMs = opts.timeoutMs
    metadata  = opts.metadata.append(GrpcMetadataEntry { key = key, value = value })
  }
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

/// Serialise call options to the comma-separated "key:value" wire format
/// consumed by the kernel.
func metadataString(opts: GrpcCallOptions): String {
  opts.metadata
    .map(func(e) { e.key + ":" + e.value })
    .joinWith(",")
}

func timeoutMs(opts: GrpcCallOptions): Int {
  opts.timeoutMs.unwrapOr(0)
}

// ─── Channel lifecycle ────────────────────────────────────────────────────────

/// Open a gRPC channel to `address`.
/// `address` must include the scheme and port, e.g. "https://host:4317".
/// Returns Err if the address is malformed or the channel cannot be created.
@cfg(feature = "dotnet")
pub func openChannel(address: String): Result[GrpcChannel, String] {
  netOpenChannel(address)
}

@cfg(feature = "jvm")
pub func openChannel(address: String): Result[GrpcChannel, String] {
  netOpenChannel(address)
}

/// Close the channel and release all HTTP/2 connections.
/// The channel must not be used after this call.
@cfg(feature = "dotnet")
pub func closeChannel(channel: GrpcChannel): Unit {
  netCloseChannel(channel)
}

@cfg(feature = "jvm")
pub func closeChannel(channel: GrpcChannel): Unit {
  netCloseChannel(channel)
}

// ─── Unary calls ─────────────────────────────────────────────────────────────

/// Make a blocking unary gRPC call.
///
/// `channel` — open channel returned by openChannel.
/// `service` — fully-qualified protobuf service name, e.g.
///   "opentelemetry.proto.collector.trace.v1.TraceService"
/// `method`  — unqualified RPC method name, e.g. "Export"
/// `payload` — protobuf-encoded request body (from Proto.encodeMessage)
/// `opts`    — deadline, metadata (use defaultOptions() for defaults)
///
/// Returns the protobuf-encoded response body on success, or a GrpcStatus
/// describing the RPC error.
@cfg(feature = "dotnet")
pub func callUnary(
  channel: GrpcChannel,
  service: String,
  method:  String,
  payload: slice[Byte],
  opts:    GrpcCallOptions
): Result[slice[Byte], GrpcStatus] {
  netCallUnary(channel, service, method, payload, timeoutMs(opts), metadataString(opts))
}

@cfg(feature = "jvm")
pub func callUnary(
  channel: GrpcChannel,
  service: String,
  method:  String,
  payload: slice[Byte],
  opts:    GrpcCallOptions
): Result[slice[Byte], GrpcStatus] {
  netCallUnary(channel, service, method, payload, timeoutMs(opts), metadataString(opts))
}

// ─── Server-streaming calls ───────────────────────────────────────────────────

/// Start a server-streaming gRPC call.
/// The request is sent immediately; responses are pulled lazily via nextMessage.
///
/// Always call closeStream when done, even if nextMessage returned None.
@cfg(feature = "dotnet")
pub func openServerStream(
  channel: GrpcChannel,
  service: String,
  method:  String,
  payload: slice[Byte],
  opts:    GrpcCallOptions
): Result[GrpcStream, GrpcStatus] {
  netOpenServerStream(channel, service, method, payload, timeoutMs(opts), metadataString(opts))
}

@cfg(feature = "jvm")
pub func openServerStream(
  channel: GrpcChannel,
  service: String,
  method:  String,
  payload: slice[Byte],
  opts:    GrpcCallOptions
): Result[GrpcStream, GrpcStatus] {
  netOpenServerStream(channel, service, method, payload, timeoutMs(opts), metadataString(opts))
}

/// Read the next message from a server-streaming response.
/// Returns Some(bytes) for each message; None when the stream ends cleanly.
/// Returns Err on RPC error or transport failure.
@cfg(feature = "dotnet")
pub func nextMessage(stream: GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  netNextStreamMessage(stream)
}

@cfg(feature = "jvm")
pub func nextMessage(stream: GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  netNextStreamMessage(stream)
}

/// Release a server-streaming response handle.
@cfg(feature = "dotnet")
pub func closeStream(stream: GrpcStream): Unit {
  netCloseStream(stream)
}

@cfg(feature = "jvm")
pub func closeStream(stream: GrpcStream): Unit {
  netCloseStream(stream)
}
