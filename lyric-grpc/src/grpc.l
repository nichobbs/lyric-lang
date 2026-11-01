//! Grpc — gRPC client and server API.
//! Stability: @experimental. The client (openChannel/closeChannel, callUnary,
//! openServerStream/nextMessage/closeStream, checkRateLimit) is real on both
//! targets and tested end to end against in-process gRPC servers
//! (Grpc.Net.Client on dotnet, grpc-java on the JVM). Server hosting
//! (start/startHandle/stop) is not implemented on either target and panics
//! naming #8642; see README.md's platform-parity table.
//!
//! Client (outbound calls):
//!   val ch = Grpc.openChannel("https://host:4317").unwrap()
//!   val resp = Grpc.callUnary(ch, "svc.Name", "Method", payload, Grpc.defaultOptions())
//!   Grpc.closeChannel(ch)
//!
//! Server (service hosting):
//!   var registry = Grpc.create()
//!   registry = Grpc.addUnary(registry, "MyService", "GetItem", { req, meta -> Ok(handle(req)) })
//!   Grpc.start(registry)              // blocks until SIGTERM
//!   val h = Grpc.startHandle(registry) // non-blocking; call Grpc.stop(h, 5000) to drain
//!
//! Payload format: raw protobuf-encoded bytes (slice[Byte]).
//! Use lyric-proto for encoding/decoding; the client layer is deliberately
//! payload-agnostic so it works for any proto schema without code generation.
//!
//! Status codes: handlers return Result[T, GrpcStatus] where GrpcStatus.code
//! is a GrpcStatusCode enum value.  Use the constructor helpers (Grpc.notFound,
//! Grpc.unavailable, etc.) rather than building GrpcStatus directly.
//!
//! Auth parameters: the gRPC server kernel extracts the "authorization" metadata
//! value and passes it as an `authToken: String` parameter to handlers that
//! declare it.  The RequiresGrpcAuth aspect (Grpc.Aspects) reads args.authToken.
//!
//! See docs/37-grpc-proto-sketch.md.
//!
//! Each public function has a `dotnet`-feature body calling `Grpc.Kernel.Net`
//! and a `jvm`-feature body calling `Grpc.Kernel.Jvm`; the feature selects
//! which one a build keeps.
@runtime_checked
@io
package Grpc

pub use Grpc.Types
import Grpc.Kernel.Net
import Grpc.Kernel.Jvm
import Std.Core
import Std.Collections
import Std.Iter
import Std.Char as Ch
import Std.String as Str

// ─── Client: default options ──────────────────────────────────────────────────
/// Default call options: no deadline, no metadata.
pub func defaultOptions(): GrpcCallOptions {
  GrpcCallOptions(timeoutMs = None, metadata = [])
}

/// Return options with a specific deadline (milliseconds from now).
pub func withTimeout(opts: in GrpcCallOptions, ms: in Int): GrpcCallOptions
  requires: ms > 0
{
  GrpcCallOptions(timeoutMs = Some(value = ms), metadata = opts.metadata)
}

/// Return options with an extra metadata entry added.
///
/// `metaKey` must be a valid gRPC metadata key and `metaValue` a valid value
/// for it (`isValidMetadataKey` / `isValidMetadataValue`): a CR or LF in a
/// value would otherwise reach the HTTP/2 header block.  For a value that
/// comes from outside the program (a forwarded token, a request field), use
/// `tryWithMetadata`, which reports an invalid entry as `Err` instead.
pub func withMetadata(opts: in GrpcCallOptions, metaKey: in String, metaValue: in String): GrpcCallOptions
  requires: isValidMetadataKey(metaKey)
  requires: isValidMetadataValue(metaKey, metaValue)
{
  val metaEntry = GrpcMetadataEntry(key = metaKey, value = metaValue)
  GrpcCallOptions(timeoutMs = opts.timeoutMs, metadata = concat(opts.metadata, [metaEntry]))
}

/// `withMetadata` for untrusted input: `Err` with a reason when the key or
/// value is not valid gRPC metadata.
pub func tryWithMetadata(
  opts: in GrpcCallOptions, metaKey: in String, metaValue: in String
): Result[GrpcCallOptions, String] {
  if not isValidMetadataKey(metaKey) {
    return Err(error = "invalid gRPC metadata key '" + metaKey + "'")
  }
  if not isValidMetadataValue(metaKey, metaValue) {
    return Err(error = "invalid value for gRPC metadata key '" + metaKey + "'")
  }
  Std.Core.Ok(value = withMetadata(opts, metaKey, metaValue))
}

/// True when `k` is a gRPC metadata key a caller may set: non-empty, only
/// lowercase ASCII letters, digits, `_`, `-` and `.`, and not in the
/// `grpc-` namespace the protocol reserves.
@pure
pub func isValidMetadataKey(k: in String): Bool {
  if k.length == 0 or k.startsWith("grpc-") {
    return false
  }
  var i = 0
  while i < k.length {
    val c = Ch.toInt(Str.charAtOrReplacement(k, i))
    val ok = (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45 or c == 46
    if not ok {
      return false
    }
    i = i + 1
  }
  true
}

/// True when `v` is a valid value for metadata key `k`.  A `-bin` key carries
/// arbitrary bytes, which the transport base64-encodes; any other key's value
/// must be printable ASCII (0x20-0x7E), so it can never carry CR, LF or NUL.
@pure
pub func isValidMetadataValue(k: in String, v: in String): Bool {
  if k.endsWith("-bin") {
    return true
  }
  var i = 0
  while i < v.length {
    val c = Ch.toInt(Str.charAtOrReplacement(v, i))
    if c < 32 or c > 126 {
      return false
    }
    i = i + 1
  }
  true
}

func metadataString(opts: in GrpcCallOptions): String {
  return encodeMetadata(opts.metadata)
}

func callTimeoutMs(opts: in GrpcCallOptions): Int {
  match opts.timeoutMs {
    case None -> return 0
    case Some(ms) -> return ms
  }
}

// ─── Client: channel lifecycle ────────────────────────────────────────────────
/// Open a gRPC channel to `address` (e.g. "https://host:4317").
/// Returns Err if the address is malformed or the channel cannot be created.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func openChannel(address: in String): Result[GrpcChannel, String] {
  return Grpc.Kernel.Net.netOpenChannel(address)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func openChannel(address: in String): Result[GrpcChannel, String] {
  return Grpc.Kernel.Jvm.netOpenChannel(address)
}

/// Close the channel and release all HTTP/2 connections.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func closeChannel(channel: in GrpcChannel): Unit {
  Grpc.Kernel.Net.netCloseChannel(channel)
}

@stable(since = "0.1")
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
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func callUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions,
): Result[slice[Byte], GrpcStatus] {
  return Grpc.Kernel.Net.netCallUnary(channel, service, method, payload, callTimeoutMs(opts), metadataString(opts))
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func callUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions,
): Result[slice[Byte], GrpcStatus] {
  return Grpc.Kernel.Jvm.netCallUnary(channel, service, method, payload, callTimeoutMs(opts), metadataString(opts))
}

// ─── Client: server-streaming calls ──────────────────────────────────────────
/// Start a server-streaming gRPC call.
/// Always call closeStream when done, even if nextMessage returned None.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func openServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions,
): Result[GrpcStream, GrpcStatus] {
  return Grpc.Kernel.Net.netOpenServerStream(
    channel,
    service,
    method,
    payload,
    callTimeoutMs(opts),
    metadataString(opts)
  )
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func openServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions,
): Result[GrpcStream, GrpcStatus] {
  return Grpc.Kernel.Jvm.netOpenServerStream(
    channel,
    service,
    method,
    payload,
    callTimeoutMs(opts),
    metadataString(opts)
  )
}

/// Read the next message from a server-streaming response.
/// Returns Some(bytes) for each message; None when the stream ends cleanly.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func nextMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  return Grpc.Kernel.Net.netNextStreamMessage(stream)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func nextMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus] {
  return Grpc.Kernel.Jvm.netNextStreamMessage(stream)
}

/// Release a server-streaming response handle.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func closeStream(stream: in GrpcStream): Unit {
  Grpc.Kernel.Net.netCloseStream(stream)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func closeStream(stream: in GrpcStream): Unit {
  Grpc.Kernel.Jvm.netCloseStream(stream)
}

// ─── Server: rate-limit wrapper (feature-gated) ───────────────────────────────
/// Per-method in-process rate-limit check.  Feature-gated so aspects compile
/// on both dotnet and jvm targets without referencing a platform-specific kernel.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func checkRateLimit(method: in String, requestsPerMinute: in Int, burstSize: in Int): Bool
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  return Grpc.Kernel.Net.checkRateLimit(method, requestsPerMinute, burstSize)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func checkRateLimit(method: in String, requestsPerMinute: in Int, burstSize: in Int): Bool
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  return Grpc.Kernel.Jvm.checkRateLimit(method, requestsPerMinute, burstSize)
}

// ─── Server: GrpcMetadata helper ─────────────────────────────────────────────
/// Read a metadata key.  Returns None if the key is absent.  Keys are
/// lowercase on the wire, so `metaKey` must be too: a lookup for
/// `"Authorization"` would otherwise miss `authorization` silently.
@stable(since = "0.1")
pub func metadataGet(entries: in slice[GrpcMetadataEntry], metaKey: in String): Option[String]
  requires: isValidMetadataKey(metaKey) or metaKey.startsWith("grpc-")
{
  for meta in entries {
    if meta.key == metaKey {
      return Some(value = meta.value)
    }
  }
  return None
}

// ─── Server: GrpcStatus constructors ─────────────────────────────────────────
/// 3 INVALID_ARGUMENT — the caller sent a malformed or out-of-range value.
@stable(since = "0.1")
pub func invalidArgument(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.InvalidArgument, message = message)
}

/// 5 NOT_FOUND — the requested resource does not exist.
@stable(since = "0.1")
pub func notFound(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.NotFound, message = message)
}

/// 6 ALREADY_EXISTS — attempt to create a resource that already exists.
@stable(since = "0.1")
pub func alreadyExists(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.AlreadyExists, message = message)
}

/// 7 PERMISSION_DENIED — caller authenticated but lacks sufficient privilege.
@stable(since = "0.1")
pub func permissionDenied(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.PermissionDenied, message = message)
}

/// 8 RESOURCE_EXHAUSTED — quota exceeded or rate limited.
@stable(since = "0.1")
pub func resourceExhausted(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.ResourceExhausted, message = message)
}

/// 9 FAILED_PRECONDITION — operation rejected due to system state.
@stable(since = "0.1")
pub func failedPrecondition(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.FailedPrecondition, message = message)
}

/// 13 INTERNAL — unexpected server-side error.
@stable(since = "0.1")
pub func grpcInternal(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.Internal, message = message)
}

/// 14 UNAVAILABLE — service temporarily unavailable; retry is appropriate.
@stable(since = "0.1")
pub func unavailable(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.Unavailable, message = message)
}

/// 16 UNAUTHENTICATED — no valid credentials were supplied.
@stable(since = "0.1")
pub func unauthenticated(message: in String): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.Unauthenticated, message = message)
}

// ─── Server: ServiceRegistry ─────────────────────────────────────────────────
// GrpcRoute and ServiceRegistry are declared in Grpc.Types so that both Grpc
// and the kernel packages (Grpc.Kernel.Net / Grpc.Kernel.Jvm) can reference
// them without a circular import.
/// Create an empty service registry.
@stable(since = "0.1")
pub func create(): ServiceRegistry {
  ServiceRegistry(routes = [])
}

/// Register a unary RPC method: `handler` receives the request message and
/// metadata and returns the response message or the status to fail with.
@stable(since = "0.2")
pub func addUnary(
  registry: in ServiceRegistry,
  service: in String,
  method: in String,
  handler: in (slice[Byte], slice[GrpcMetadataEntry]) -> Result[slice[Byte], GrpcStatus],
): ServiceRegistry
  requires: service.length > 0
  requires: method.length > 0
  requires: not hasRoute(registry, service, method)
{
  val route = GrpcRoute(service = service, method = method, handler = GrpcHandler.Unary(handle = handler))
  return ServiceRegistry(routes = concat(registry.routes, [route]))
}

/// Register a server-streaming RPC method: `handler` sends each response
/// message through `emit` (which returns `false` once the client has gone
/// away) and returns `Ok(())` to finish or the status to fail with.
@stable(since = "0.2")
pub func addServerStreaming(
  registry: in ServiceRegistry,
  service: in String,
  method: in String,
  handler: in (slice[Byte], slice[GrpcMetadataEntry], (slice[Byte]) -> Bool) -> Result[Unit, GrpcStatus],
): ServiceRegistry
  requires: service.length > 0
  requires: method.length > 0
  requires: not hasRoute(registry, service, method)
{
  val route = GrpcRoute(service = service, method = method, handler = GrpcHandler.ServerStreaming(handle = handler))
  return ServiceRegistry(routes = concat(registry.routes, [route]))
}

@pure
func hasRoute(registry: in ServiceRegistry, service: in String, method: in String): Bool {
  match findRoute(registry, service, method) {
    case Some(_) -> true
    case None -> false
  }
}

// ─── Server: entry point ──────────────────────────────────────────────────────
config GrpcServer {
  host: String = "0.0.0.0"
  port: Int range 1 ..= 65535 = 50051
  reflectionEnabled: Bool = false
  maxConnectionIdleMs: Int range 1 ..= 2147483647 = 300000
}

/// The reason `GrpcServer` cannot be used, or "" when it can.  The values come
/// from the environment, so a bad one is reported when the server starts
/// rather than as an obscure bind failure.
pub func serverConfigProblem(): String {
  if GrpcServer.port < 1 or GrpcServer.port > 65535 {
    return "GrpcServer.port must be in 1..65535, got " + GrpcServer.port.toString()
  }
  if GrpcServer.maxConnectionIdleMs <= 0 {
    return "GrpcServer.maxConnectionIdleMs must be positive, got " + GrpcServer.maxConnectionIdleMs.toString()
  }
  ""
}

func checkServerConfig(): Unit {
  val problem = serverConfigProblem()
  if problem != "" {
    panic("Grpc: " + problem)
  }
}

/// Start the gRPC server and block serving it until the process exits.
/// Panics before binding when `GrpcServer` is misconfigured
/// (`serverConfigProblem`) or when the address cannot be bound.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func start(registry: in ServiceRegistry): Unit {
  checkServerConfig()
  Grpc.Kernel.Net.serve(
    GrpcServer.host,
    GrpcServer.port,
    GrpcServer.reflectionEnabled,
    GrpcServer.maxConnectionIdleMs,
    registry
  )
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func start(registry: in ServiceRegistry): Unit {
  checkServerConfig()
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
@stable(since = "0.1")
pub func startHandle(registry: in ServiceRegistry): GrpcServerHandle {
  checkServerConfig()
  return startHandleAt(registry, GrpcServer.host, GrpcServer.port)
}

/// `startHandle` on an explicit address instead of the `GrpcServer` config's
/// `host` and `port`. `port = 0` binds an ephemeral port: read it back with
/// `serverPort`. `host` is an IP literal. Panics when the address cannot be
/// bound.
@stable(since = "0.2")
@cfg(feature = "dotnet")
pub func startHandleAt(registry: in ServiceRegistry, host: in String, port: in Int): GrpcServerHandle
  requires: port >= 0 and port <= 65535
{
  return Grpc.Kernel.Net.netStartHandle(
    host,
    port,
    GrpcServer.reflectionEnabled,
    GrpcServer.maxConnectionIdleMs,
    registry
  )
}

@stable(since = "0.2")
@cfg(feature = "jvm")
pub func startHandleAt(registry: in ServiceRegistry, host: in String, port: in Int): GrpcServerHandle
  requires: port >= 0 and port <= 65535
{
  return Grpc.Kernel.Jvm.netStartHandle(
    host,
    port,
    GrpcServer.reflectionEnabled,
    GrpcServer.maxConnectionIdleMs,
    registry
  )
}

/// The port a running server is bound to.
@stable(since = "0.2")
@cfg(feature = "dotnet")
pub func serverPort(handle: in GrpcServerHandle): Int {
  Grpc.Kernel.Net.netServerPort(handle)
}

@stable(since = "0.2")
@cfg(feature = "jvm")
pub func serverPort(handle: in GrpcServerHandle): Int {
  Grpc.Kernel.Jvm.netServerPort(handle)
}

/// Stop the gRPC server, waiting up to `drainTimeoutMs` milliseconds for
/// in-flight RPCs to complete before forcibly closing connections.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func stop(handle: in GrpcServerHandle, drainTimeoutMs: in Int): Unit
  requires: drainTimeoutMs >= 0
{
  Grpc.Kernel.Net.netStopHandle(handle, drainTimeoutMs)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func stop(handle: in GrpcServerHandle, drainTimeoutMs: in Int): Unit
  requires: drainTimeoutMs >= 0
{
  Grpc.Kernel.Jvm.netStopHandle(handle, drainTimeoutMs)
}
