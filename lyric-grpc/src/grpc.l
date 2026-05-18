/// Grpc — gRPC client and server API.
///
/// Client (outbound calls):
///   val ch = Grpc.openChannel("https://host:4317").unwrap()
///   val resp = Grpc.callUnary(ch, "svc.Name", "Method", payload, Grpc.defaultOptions())
///   Grpc.closeChannel(ch)
///
/// Server (service hosting):
///   val registry = Grpc.create()
///   val registry = Grpc.addMethod(registry, "MyService", "GetItem", "Pkg.handler")
///   Grpc.start(registry)              // blocks until SIGTERM
///   val h = Grpc.startHandle(registry) // non-blocking; call Grpc.stop(h, 5000) to drain
///
/// Payload format: raw protobuf-encoded bytes (slice[Byte]).
/// Use lyric-proto for encoding/decoding; the client layer is deliberately
/// payload-agnostic so it works for any proto schema without code generation.
///
/// Status codes: handlers return Result[T, GrpcStatus] where GrpcStatus.code
/// is a GrpcStatusCode enum value.  Use the constructor helpers (Grpc.notFound,
/// Grpc.unavailable, etc.) rather than building GrpcStatus directly.
///
/// Auth parameters: the gRPC server kernel extracts the "authorization" metadata
/// value and passes it as an `authToken: String` parameter to handlers that
/// declare it.  The RequiresGrpcAuth aspect (Grpc.Aspects) reads args.authToken.
///
/// See docs/37-grpc-proto-sketch.md.

@runtime_checked
package Grpc

import Grpc.Types
import Grpc.Kernel.Net
import Grpc.Kernel.Jvm
import Std.Core
import Std.Collections

// ─── Client: default options ──────────────────────────────────────────────────

/// Default call options: no deadline, no metadata.
pub func defaultOptions(): GrpcCallOptions {
  GrpcCallOptions(timeoutMs = None, metadata = [])
}

/// Return options with a specific deadline (milliseconds from now).
pub func withTimeout(opts: in GrpcCallOptions, ms: in Int): GrpcCallOptions {
  GrpcCallOptions(timeoutMs = Some(value = ms), metadata = opts.metadata)
}

/// Return options with an extra metadata entry added.
pub func withMetadata(opts: in GrpcCallOptions, key: in String, value: in String): GrpcCallOptions {
  val entry = GrpcMetadataEntry(key = key, value = value)
  GrpcCallOptions(timeoutMs = opts.timeoutMs, metadata = opts.metadata + [entry])
}

// Percent-encode metadata key/value segments for the comma-and-colon-delimited
// metadataString wire format.  The BCL kernel bridges (both .NET and JVM) must
// percent-decode each segment after splitting on ',' and ':' before passing
// values to the underlying gRPC library — otherwise metadata containing ','
// or ':' will be delivered as "%2C" / "%3A" literals.  This encode/decode
// pairing has been verified in both kernel bridges (see lyric-lang #514).
func percentEncodeMetadata(s: in String): String {
  // Three sequential single-pass substitutions — O(n) each, total O(n).
  // Encode `%` first so the replacement strings below are not re-encoded.
  val a = Str.replace(s, "%", "%25")
  val b = Str.replace(a, ",", "%2C")
  Str.replace(b, ":", "%3A")
}

func metadataString(opts: in GrpcCallOptions): String {
  var result: String = ""
  for entry in opts.metadata {
    if result.length > 0 { result = result + "," }
    result = result + percentEncodeMetadata(entry.key) + ":" + percentEncodeMetadata(entry.value)
  }
  return result
}

func callTimeoutMs(opts: in GrpcCallOptions): Int {
  match opts.timeoutMs {
    case None         -> return 0
    case Some(value = ms) -> return ms
  }
}

// ─── Client: channel lifecycle ────────────────────────────────────────────────

/// Open a gRPC channel to `address` (e.g. "https://host:4317").
/// Returns Err if the address is malformed or the channel cannot be created.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func openChannel(address: in String): Result[GrpcChannel, String] {
  return Grpc.Kernel.Net.netOpenChannel(address)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func openChannel(address: in String): Result[GrpcChannel, String] {
  return Grpc.Kernel.Jvm.netOpenChannel(address)
}

/// Close the channel and release all HTTP/2 connections.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func closeChannel(channel: in GrpcChannel): Unit {
  Grpc.Kernel.Net.netCloseChannel(channel)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func closeChannel(channel: in GrpcChannel): Unit {
  Grpc.Kernel.Jvm.netCloseChannel(channel)
}

// ─── Client: unary calls ──────────────────────────────────────────────────────

/// Make a blocking unary gRPC call.
///
/// `service` — fully-qualified proto service name (e.g. "pkg.MyService")
/// `method`  — unqualified RPC method name (e.g. "GetItem")
/// `payload` — protobuf-encoded request body
/// `opts`    — deadline and metadata (use defaultOptions() for defaults)
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func callUnary(
  channel: in GrpcChannel,
  service: in String,
  method:  in String,
  payload: in slice[Byte],
  opts:    in GrpcCallOptions
): Result[slice[Byte], GrpcStatus] {
  return Grpc.Kernel.Net.netCallUnary(channel, service, method, payload, callTimeoutMs(opts), metadataString(opts))
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func callUnary(
  channel: in GrpcChannel,
  service: in String,
  method:  in String,
  payload: in slice[Byte],
  opts:    in GrpcCallOptions
): Result[slice[Byte], GrpcStatus] {
  return Grpc.Kernel.Jvm.netCallUnary(channel, service, method, payload, callTimeoutMs(opts), metadataString(opts))
}

// ─── Client: server-streaming calls ──────────────────────────────────────────

/// Start a server-streaming gRPC call.
/// Always call closeStream when done, even if nextMessage returned None.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func openServerStream(
  channel: in GrpcChannel,
  service: in String,
  method:  in String,
  payload: in slice[Byte],
  opts:    in GrpcCallOptions
): Result[GrpcStream, GrpcStatus] {
  return Grpc.Kernel.Net.netOpenServerStream(channel, service, method, payload, callTimeoutMs(opts), metadataString(opts))
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func openServerStream(
  channel: in GrpcChannel,
  service: in String,
  method:  in String,
  payload: in slice[Byte],
  opts:    in GrpcCallOptions
): Result[GrpcStream, GrpcStatus] {
  return Grpc.Kernel.Jvm.netOpenServerStream(channel, service, method, payload, callTimeoutMs(opts), metadataString(opts))
}

/// Read the next message from a server-streaming response.
/// Returns Some(bytes) for each message; None when the stream ends cleanly.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func nextMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  return Grpc.Kernel.Net.netNextStreamMessage(stream)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func nextMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  return Grpc.Kernel.Jvm.netNextStreamMessage(stream)
}

/// Release a server-streaming response handle.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func closeStream(stream: in GrpcStream): Unit {
  Grpc.Kernel.Net.netCloseStream(stream)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func closeStream(stream: in GrpcStream): Unit {
  Grpc.Kernel.Jvm.netCloseStream(stream)
}

// ─── Server: rate-limit wrapper (feature-gated) ───────────────────────────────

/// Per-method in-process rate-limit check.  Feature-gated so aspects compile
/// on both dotnet and jvm targets without referencing a platform-specific kernel.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func checkRateLimit(method: in String, requestsPerMinute: in Int, burstSize: in Int): Bool
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  return Grpc.Kernel.Net.checkRateLimit(method, requestsPerMinute, burstSize)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func checkRateLimit(method: in String, requestsPerMinute: in Int, burstSize: in Int): Bool
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  return Grpc.Kernel.Jvm.checkRateLimit(method, requestsPerMinute, burstSize)
}

// ─── Server: GrpcMetadata helper ─────────────────────────────────────────────

/// Read a metadata key.  Returns None if the key is absent.
@stable(since="0.1")
pub func metadataGet(entries: in [GrpcMetadataEntry], key: in String): Option[String] {
  for entry in entries {
    if entry.key == key { return Some(value = entry.value) }
  }
  return None
}

// ─── Server: GrpcStatus constructors ─────────────────────────────────────────

/// 3 INVALID_ARGUMENT — the caller sent a malformed or out-of-range value.
@stable(since="0.1")
pub func invalidArgument(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.InvalidArgument, message = message)
}

/// 5 NOT_FOUND — the requested resource does not exist.
@stable(since="0.1")
pub func notFound(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.NotFound, message = message)
}

/// 6 ALREADY_EXISTS — attempt to create a resource that already exists.
@stable(since="0.1")
pub func alreadyExists(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.AlreadyExists, message = message)
}

/// 7 PERMISSION_DENIED — caller authenticated but lacks sufficient privilege.
@stable(since="0.1")
pub func permissionDenied(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.PermissionDenied, message = message)
}

/// 8 RESOURCE_EXHAUSTED — quota exceeded or rate limited.
@stable(since="0.1")
pub func resourceExhausted(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.ResourceExhausted, message = message)
}

/// 9 FAILED_PRECONDITION — operation rejected due to system state.
@stable(since="0.1")
pub func failedPrecondition(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.FailedPrecondition, message = message)
}

/// 13 INTERNAL — unexpected server-side error.
@stable(since="0.1")
pub func internal(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.Internal, message = message)
}

/// 14 UNAVAILABLE — service temporarily unavailable; retry is appropriate.
@stable(since="0.1")
pub func unavailable(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.Unavailable, message = message)
}

/// 16 UNAUTHENTICATED — no valid credentials were supplied.
@stable(since="0.1")
pub func unauthenticated(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.Unauthenticated, message = message)
}

// ─── Server: ServiceRegistry ─────────────────────────────────────────────────
// GrpcRoute and ServiceRegistry are declared in Grpc.Types so that both Grpc
// and the kernel packages (Grpc.Kernel.Net / Grpc.Kernel.Jvm) can reference
// them without a circular import.

/// Create an empty service registry.
@stable(since="0.1")
pub func create(): ServiceRegistry {
  ServiceRegistry(routes = [])
}

/// Register a single RPC method.
@stable(since="0.1")
pub func addMethod(
  registry:    in ServiceRegistry,
  service:     in String,
  method:      in String,
  handlerName: in String
): ServiceRegistry
  requires: service.length > 0
  requires: method.length > 0
  requires: handlerName.length > 0
{
  val route = GrpcRoute(service = service, method = method, handlerName = handlerName)
  return ServiceRegistry(routes = registry.routes + [route])
}

// ─── Server: entry point ──────────────────────────────────────────────────────

config GrpcServer {
  host:                String = "0.0.0.0"
  port:                Int    = 50051
  reflectionEnabled:   Bool   = false
  maxConnectionIdleMs: Int    = 300000
}

/// Start the gRPC server.  Blocks until SIGTERM / SIGINT.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func start(registry: in ServiceRegistry): Unit {
  Grpc.Kernel.Net.serve(
    GrpcServer.host,
    GrpcServer.port,
    GrpcServer.reflectionEnabled,
    GrpcServer.maxConnectionIdleMs,
    registry
  )
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func start(registry: in ServiceRegistry): Unit {
  Grpc.Kernel.Jvm.serve(
    GrpcServer.host,
    GrpcServer.port,
    GrpcServer.reflectionEnabled,
    GrpcServer.maxConnectionIdleMs,
    registry
  )
}

// ─── Server: non-blocking start with graceful stop ────────────────────────────

/// Start the gRPC server and return a handle that can be used to stop it.
/// Unlike `start`, this function returns immediately; the server runs in the
/// background.  Call `stop` to drain in-flight RPCs and shut it down.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func startHandle(registry: in ServiceRegistry): GrpcServerHandle {
  return Grpc.Kernel.Net.netStartHandle(
    GrpcServer.host,
    GrpcServer.port,
    GrpcServer.reflectionEnabled,
    GrpcServer.maxConnectionIdleMs,
    registry
  )
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func startHandle(registry: in ServiceRegistry): GrpcServerHandle {
  return Grpc.Kernel.Jvm.netStartHandle(
    GrpcServer.host,
    GrpcServer.port,
    GrpcServer.reflectionEnabled,
    GrpcServer.maxConnectionIdleMs,
    registry
  )
}

/// Stop the gRPC server, waiting up to `drainTimeoutMs` milliseconds for
/// in-flight RPCs to complete before forcibly closing connections.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func stop(handle: in GrpcServerHandle, drainTimeoutMs: in Int): Unit
  requires: drainTimeoutMs >= 0
  requires: drainTimeoutMs <= 300000
{
  Grpc.Kernel.Net.netStopHandle(handle, drainTimeoutMs)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func stop(handle: in GrpcServerHandle, drainTimeoutMs: in Int): Unit
  requires: drainTimeoutMs >= 0
  requires: drainTimeoutMs <= 300000
{
  Grpc.Kernel.Jvm.netStopHandle(handle, drainTimeoutMs)
}
