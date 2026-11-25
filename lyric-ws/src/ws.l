//! Ws — WebSocket server library for Lyric.
//! Stability: @experimental — the connection lifecycle compiles and the WsAuth
//! aspect has tests.  `startServer` is backed by a real running server on
//! every target: pure-Lyric RFC 6455 over `Std.TcpHost` (`Ws.Kernel.Net`,
//! docs/62-jsonrpc-mcp.md §6, #778, docs/73 S7a) on dotnet, the JVM and
//! native, with fragmented multi-frame message reassembly and automatic ping
//! keepalive (see `Ws.Kernel.Net`'s header).  A `createEndpoint` endpoint
//! served by `lyric-web` on the JVM is still Undertow-backed until docs/73 S7b
//! (see `Ws.Kernel.Jvm`'s header for the gaps that carries).
//!
//! Provides the full connection lifecycle for WebSocket servers:
//! connection context, message types, a handler interface for
//! application logic, and a registry interface for sending to
//! connected clients.
//!
//! Typical usage:
//!
//!   import Ws
//!
//!   // Implement WsHandler for application logic
//!   record MyHandler {}
//!   impl WsHandler for MyHandler {
//!     func onOpen(ctx: in WsContext): Result[Unit, WsError] { ... }
//!     func onMessage(ctx: in WsContext, msg: in WsMessage): Result[Unit, WsError] { ... }
//!     func onClose(ctx: in WsContext, code: in WsCloseCode): Unit { ... }
//!     func onError(ctx: in WsContext, error: in WsError): Unit { ... }
//!   }
//!
//!   // Start a real server bound to the handler (real on both targets; see above)
//!   match Ws.startServer("0.0.0.0", 8080, "/ws", MyHandler()) {
//!     case Ok(registry) -> ...   // push via Ws.sendText(registry, connId, "hi")
//!     case Err(e) -> ...
//!   }
//!
//! Runtime config env vars (LYRIC_CONFIG_WS_SERVER_*):
//!   LYRIC_CONFIG_WS_SERVER_PATH                — WebSocket upgrade path (default: /ws)
//!   LYRIC_CONFIG_WS_SERVER_MAXMESSAGESIZEBYTES — max frame size in bytes (default: 65536)
//!   LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS      — ping interval in milliseconds (default: 30000)
//!   LYRIC_CONFIG_WS_SERVER_HANDSHAKETIMEOUTMS  — upgrade handshake timeout (default: 10000)
//!   LYRIC_CONFIG_WS_AUTH_ENABLED               — enable JWT gate on upgrade (default: true)
//!   LYRIC_CONFIG_WS_AUTH_JWTSECRET             — HMAC-SHA256 secret for JWT (required when auth enabled)
//!   LYRIC_CONFIG_WS_AUTH_ISSUER                — expected iss claim (default: "")
//!   LYRIC_CONFIG_WS_AUTH_AUDIENCE              — expected aud claim (default: "")
@runtime_checked
@io
package Ws

import Std.Core
import Std.Collections
import Std.Tls as Tls
import Ws.Frame
import Ws.Kernel.Net as WsKernelNet
import Ws.Kernel.Jvm as WsKernelJvm

// Kernel boundary: every BCL / JDK interaction goes through a platform
// kernel.  `Ws.Kernel.Net` is the pure-Lyric RFC 6455 server over
// `Std.TcpHost` and runs on every target; it serves `startServer` and the
// rate limiter everywhere.  Endpoints (`createEndpoint`, used by
// `Web.addWebSocket`) are `Ws.Kernel.Net` registries on every target since
// docs/73 S6: `lyric-web` on the JVM serves through `Std.HttpServer` and hands
// an upgrade over with `takeConnection`.  `Ws.Kernel.Jvm`'s Undertow endpoint
// handler is therefore no longer reachable; its `ownsHandle` routing below
// stays until docs/73 S7b deletes the package.  A registry handle says which
// kernel owns it (`WsKernelJvm.ownsHandle`), so the `kernelXxx` wrappers
// route by handle on the JVM.  This file is the
// public surface of the library; it must not declare its own `@axiom`
// stubs (doing so previously shadowed the kernel boundary and broke
// the trust-boundary audit — see lyric-lang #739).  The kernels only ever
// exchange primitive types (String/Int) with this file — never `WsHandler`/
// `WsContext`/`WsMessage` — so neither kernel needs to import `Ws` itself,
// avoiding an `Ws` <-> kernel import cycle.
func kernelCreateRegistry(maxMessageSizeBytes: in Int, pingIntervalMs: in Int): Result[Int, String] {
  WsKernelNet.createRegistry(maxMessageSizeBytes, pingIntervalMs)
}

func kernelStartServer(
  host: in String,
  port: in Int,
  path: in String,
  maxMessageSizeBytes: in Int,
  allowedOrigins: in slice[String],
  sameHostPorts: in slice[Int],
  limits: in WsKernelNet.ServerLimits,
  tls: in Option[Tls.TlsServerConfig],
  onOpen: in (String, String, String, String, Map[String, String]) -> Unit,
  onMessage: in (String, String, String) -> Unit,
  onClose: in (String, Int, String) -> Unit,
  onError: in (String, String) -> Unit,
): Result[Int, String] {
  WsKernelNet.startServerWith(
    host,
    port,
    path,
    maxMessageSizeBytes,
    allowedOrigins,
    sameHostPorts,
    limits,
    tls,
    onOpen,
    onMessage,
    onClose,
    onError
  )
}

func kernelCreateEndpoint(
  maxMessageSizeBytes: in Int,
  limits: in WsKernelNet.ServerLimits,
  onOpen: in (String, String, String, String, Map[String, String]) -> Unit,
  onMessage: in (String, String, String) -> Unit,
  onClose: in (String, Int, String) -> Unit,
  onError: in (String, String) -> Unit,
): Result[Int, String] {
  WsKernelNet.createEndpointWith(maxMessageSizeBytes, limits, onOpen, onMessage, onClose, onError)
}

/// Per-key token-bucket rate check (`Resilience.takeToken`) shared by `Ws.Aspects.WsRateLimit`.
@stable(since = "0.2")
pub func checkRateLimit(key: in String, messagesPerMinute: in Int, burstSize: in Int): Bool
  requires: key.length > 0
  requires: messagesPerMinute > 0
  requires: burstSize > 0
{
  WsKernelNet.checkRateLimit(key, messagesPerMinute, burstSize)
}

@cfg(any(feature = "dotnet", feature = "native"))
func kernelStopServer(registryHandle: in Int): Result[Unit, String] {
  WsKernelNet.stopServer(registryHandle)
}

@cfg(feature = "jvm")
func kernelStopServer(registryHandle: in Int): Result[Unit, String] {
  if WsKernelJvm.ownsHandle(registryHandle) {
    WsKernelJvm.stopServer(registryHandle)
  } else {
    WsKernelNet.stopServer(registryHandle)
  }
}

@cfg(any(feature = "dotnet", feature = "native"))
func kernelSend(
  registryHandle: in Int, connectionId: in String, messageType: in String, data: in String
): Result[Unit, String] {
  WsKernelNet.send(registryHandle, connectionId, messageType, data)
}

@cfg(feature = "jvm")
func kernelSend(
  registryHandle: in Int, connectionId: in String, messageType: in String, data: in String
): Result[Unit, String] {
  if WsKernelJvm.ownsHandle(registryHandle) {
    WsKernelJvm.send(registryHandle, connectionId, messageType, data)
  } else {
    WsKernelNet.send(registryHandle, connectionId, messageType, data)
  }
}

@cfg(any(feature = "dotnet", feature = "native"))
func kernelBroadcast(registryHandle: in Int, messageType: in String, data: in String): Result[Unit, String] {
  WsKernelNet.broadcast(registryHandle, messageType, data)
}

@cfg(feature = "jvm")
func kernelBroadcast(registryHandle: in Int, messageType: in String, data: in String): Result[Unit, String] {
  if WsKernelJvm.ownsHandle(registryHandle) {
    WsKernelJvm.broadcast(registryHandle, messageType, data)
  } else {
    WsKernelNet.broadcast(registryHandle, messageType, data)
  }
}

@cfg(any(feature = "dotnet", feature = "native"))
func kernelClose(registryHandle: in Int, connectionId: in String, code: in Int, reason: in String): Result[Unit, String] {
  WsKernelNet.close(registryHandle, connectionId, code, reason)
}

@cfg(feature = "jvm")
func kernelClose(registryHandle: in Int, connectionId: in String, code: in Int, reason: in String): Result[Unit, String] {
  if WsKernelJvm.ownsHandle(registryHandle) {
    WsKernelJvm.close(registryHandle, connectionId, code, reason)
  } else {
    WsKernelNet.close(registryHandle, connectionId, code, reason)
  }
}

@cfg(any(feature = "dotnet", feature = "native"))
func kernelConnectionCount(registryHandle: in Int): Int {
  WsKernelNet.connectionCount(registryHandle)
}

@cfg(feature = "jvm")
func kernelConnectionCount(registryHandle: in Int): Int {
  if WsKernelJvm.ownsHandle(registryHandle) {
    WsKernelJvm.connectionCount(registryHandle)
  } else {
    WsKernelNet.connectionCount(registryHandle)
  }
}

@cfg(any(feature = "dotnet", feature = "native"))
func kernelIsConnected(registryHandle: in Int, connectionId: in String): Bool {
  WsKernelNet.isConnected(registryHandle, connectionId)
}

@cfg(feature = "jvm")
func kernelIsConnected(registryHandle: in Int, connectionId: in String): Bool {
  if WsKernelJvm.ownsHandle(registryHandle) {
    WsKernelJvm.isConnected(registryHandle, connectionId)
  } else {
    WsKernelNet.isConnected(registryHandle, connectionId)
  }
}

// ─── Connection identity ──────────────────────────────────────────────────────
/// Opaque identifier for a single WebSocket connection.
/// Assigned by the kernel at upgrade time and stable until close.
@stable(since = "0.1")
pub type WsConnectionId = String

// ─── Close codes ─────────────────────────────────────────────────────────────
/// RFC 6455 close codes sent in Close frames.
@stable(since = "0.1")
pub union WsCloseCode {
  case Normal(code: Int)
  case GoingAway
  case ProtocolError
  case PolicyViolation
  case InternalError
}

// ─── Message types ────────────────────────────────────────────────────────────
/// A WebSocket frame payload.
@stable(since = "0.1")
pub union WsMessage {
  /// UTF-8 text frame.
  case Text(text: String)
  /// Binary frame with Base64-encoded payload.
  case Binary(dataBase64: String)
  /// Ping control frame.
  case Ping
  /// Pong control frame.
  case Pong
  /// Close frame with a close code (RFC 6455 numeric code) and human-readable reason.
  case Close(code: Int, reason: String)
}

// ─── Error ────────────────────────────────────────────────────────────────────
/// Error produced by WebSocket operations.
@stable(since = "0.1")
pub record WsError {
  message: String
  code: String
  connectionId: String
}

// ─── Connection context ───────────────────────────────────────────────────────
/// Snapshot of a WebSocket connection's metadata, available in every callback.
/// `headers` holds the upgrade request's headers (lower-cased names) in the
/// `onOpen` context; the later callbacks carry an empty map, so a handler
/// that needs a header afterwards keeps it keyed by `connectionId`.
@stable(since = "0.1")
pub record WsContext {
  connectionId: String
  path: String
  query: String
  remoteAddress: String
  headers: Map[String, String]
}

// ─── Handler interface ────────────────────────────────────────────────────────
/// Application-level WebSocket handler.  Implement this interface to receive
/// connection lifecycle and message events.  Return Err to signal that a
/// problem occurred; the kernel will close the connection with InternalError.
@stable(since = "0.1")
pub interface WsHandler {
  /// Called when a new connection is upgraded and ready to exchange frames.
  func onOpen(ctx: in WsContext): Result[Unit, WsError]

  /// Called for each incoming Text, Binary, Ping, or Pong frame.
  func onMessage(ctx: in WsContext, msg: in WsMessage): Result[Unit, WsError]

  /// Called when the connection closes cleanly.
  func onClose(ctx: in WsContext, code: in WsCloseCode): Unit

  /// Called when the kernel encounters a transport-level error.
  func onError(ctx: in WsContext, error: in WsError): Unit
}

// ─── Registry interface ───────────────────────────────────────────────────────
/// Server-side connection registry.  Use this to push frames to connected
/// clients from outside the handler callbacks.
@stable(since = "0.1")
pub interface WsRegistry {
  /// Send a message to a single connection.
  func send(connectionId: in String, msg: in WsMessage): Result[Unit, WsError]

  /// Broadcast a message to all currently connected clients.
  func broadcast(msg: in WsMessage): Result[Unit, WsError]

  /// Close a connection with the given code and reason.
  func close(connectionId: in String, code: in WsCloseCode, reason: in String): Result[Unit, WsError]

  /// Return the number of currently open connections.
  func connectionCount(): Int

  /// Return whether the given connection is currently open.
  func isConnected(connectionId: in String): Bool
}

// ─── Native registry ──────────────────────────────────────────────────────────
/// Kernel-backed registry implementation.  Obtain via `createRegistry()`.
@stable(since = "0.1")
pub record NativeRegistry {
  registryHandle: Int
}

impl WsRegistry for NativeRegistry {
  func send(connectionId: in String, msg: in WsMessage): Result[Unit, WsError] {
    val msgType = messageTypeString(msg)
    val msgData = messageDataString(msg)
    val rh = self.registryHandle
    match kernelSend(rh, connectionId, msgType, msgData) {
      case Ok(u) -> Ok(u)
      case Err(err) -> Err(WsError(message = err, code = "SEND_FAILED", connectionId = connectionId))
    }
  }

  func broadcast(msg: in WsMessage): Result[Unit, WsError] {
    val msgType = messageTypeString(msg)
    val msgData = messageDataString(msg)
    val rh = self.registryHandle
    match kernelBroadcast(rh, msgType, msgData) {
      case Ok(u) -> Ok(u)
      case Err(err) -> Err(WsError(message = err, code = "BROADCAST_FAILED", connectionId = ""))
    }
  }

  func close(connectionId: in String, code: in WsCloseCode, reason: in String): Result[Unit, WsError] {
    val codeInt = closeCodeToInt(code)
    if not isSendableCloseCode(codeInt) {
      return Err(
        WsError(
          message = "close code " + codeInt.toString() + " may not be sent: use 1000-4999 except 1004-1006 and 1015",
          code = "INVALID_CLOSE_CODE",
          connectionId = connectionId
        )
      )
    }
    val rh = self.registryHandle
    match kernelClose(rh, connectionId, codeInt, reason) {
      case Ok(u) -> Ok(u)
      case Err(err) -> Err(WsError(message = err, code = "CLOSE_FAILED", connectionId = connectionId))
    }
  }

  func connectionCount(): Int {
    val rh = self.registryHandle
    return kernelConnectionCount(rh)
  }

  func isConnected(connectionId: in String): Bool {
    val rh = self.registryHandle
    return kernelIsConnected(rh, connectionId)
  }
}

// ─── Factory ──────────────────────────────────────────────────────────────────
/// Create a kernel-backed connection registry.
/// The registry manages WebSocket connection lifecycle.
@stable(since = "0.1")
pub func createRegistry(): Result[NativeRegistry, WsError] {
  match kernelCreateRegistry(65536, 30000) {
    case Ok(handle) -> Ok(NativeRegistry(registryHandle = handle))
    case Err(err) -> Err(WsError(message = err, code = "REGISTRY_INIT_FAILED", connectionId = ""))
  }
}

// ─── Server ───────────────────────────────────────────────────────────────────
/// Server options for `startServerWithOptions`.
///
/// `allowedOrigins` controls the cross-site WebSocket hijacking defence
/// (#7243).  A browser sends `Origin` on every WebSocket handshake and
/// attaches the site's cookies even when another site opens the socket, so
/// a handshake is refused with `403 Forbidden`, before the upgrade, unless:
/// - it has no `Origin` header (a non-browser client);
/// - its `Origin` host and port equal its `Host` header (same origin, the
///   default with an empty list);
/// - its `Origin` equals an entry of `allowedOrigins`, such as
///   `"https://app.example.com"`, ignoring ASCII case;
/// - its `Origin` host equals the `Host` header's host and its port is one
///   of `sameHostPorts`: a page the same application serves on a sibling
///   port, such as an HTTP listener next to this WebSocket listener; or
/// - `allowedOrigins` contains `"*"`, which disables the check.
///
/// The remaining fields bound what one peer can cost the server (docs/73 S8,
/// D792); `0` turns a bound off, except `maxConnections`, where it means the
/// target's default (10 000 on the JVM, 1 000 on dotnet and native):
/// - `maxConnections`: connections admitted at once, handshakes included; one
///   more is answered `503 Service Unavailable` (a `wss` listener just closes
///   it) and `connectionCount` does not count it.
/// - `idleTimeoutMs` (default 90 000, three default ping intervals): a
///   connection that has received nothing for this long, a Pong to the
///   keepalive Ping included, is closed with 1001.
/// - `writeTimeoutMs` (default 10 000): a write that makes no progress for
///   this long ends the connection (`onError`, then `onClose` with 1008).
/// - `maxOutboundBytes` (default 1 MiB, at least one frame): bytes queued for
///   one connection. `send` and `broadcast` return once a frame is queued; a
///   connection whose backlog would pass this is dropped (`send` returns
///   `Err`, `onError`, `onClose` 1008), so one slow consumer never delays
///   the others.
/// - `handshakeTimeoutMs` (default 10 000): the TLS and HTTP upgrade handshake.
@stable(since = "0.2")
pub record WsServerOptions {
  maxMessageSizeBytes: Int = 65536
  allowedOrigins: slice[String] = []
  sameHostPorts: slice[Int] = []
  maxConnections: Int = 0
  idleTimeoutMs: Int = 90000
  writeTimeoutMs: Int = 10000
  maxOutboundBytes: Int = 1048576
  handshakeTimeoutMs: Int = 10000
  invariant: maxMessageSizeBytes >= 1024 and maxMessageSizeBytes <= 67108864
  invariant: maxConnections >= 0
  invariant: idleTimeoutMs >= 0
  invariant: writeTimeoutMs >= 0
  invariant: maxOutboundBytes >= 1024
  invariant: handshakeTimeoutMs >= 0
}

func kernelLimits(options: in WsServerOptions): WsKernelNet.ServerLimits {
  WsKernelNet.ServerLimits(
    maxConnections = options.maxConnections,
    idleTimeoutMs = options.idleTimeoutMs,
    writeTimeoutMs = options.writeTimeoutMs,
    maxOutboundBytes = options.maxOutboundBytes,
    handshakeTimeoutMs = options.handshakeTimeoutMs
  )
}

/// Start a real WebSocket server bound to `handler`, listening on
/// `host:port` and upgrading exactly `path` to WebSocket.  Non-blocking:
/// returns once the server is listening.  Use the returned registry to push
/// messages from outside the handler callbacks; call `stopServer` to shut
/// down.  Uses the default `WsServerOptions` (65536-byte max message size,
/// same-origin handshakes only) — see `startServerWithOptions`.
///
/// See the module header: one pure-Lyric RFC 6455 server over `Std.TcpHost`
/// on `--target dotnet`, `--target jvm` and `--target native`.
@stable(since = "0.1")
pub func startServer(
  host: in String, port: in Int, path: in String, handler: in WsHandler
): Result[NativeRegistry, WsError]
  requires: host.length > 0
  requires: port >= 1 and port <= 65535
  requires: path.startsWith("/")
{
  startServerWithOptions(host, port, path, WsServerOptions(), handler)
}

/// As `startServer`, with an explicit max message size in bytes
/// (1024 to 67108864).
@stable(since = "0.1")
pub func startServerWithConfig(
  host: in String,
  port: in Int,
  path: in String,
  maxMessageSizeBytes: in Int,
  handler: in WsHandler,
): Result[NativeRegistry, WsError]
  requires: host.length > 0
  requires: port >= 1 and port <= 65535
  requires: path.startsWith("/")
{
  startServerWithOptions(host, port, path, WsServerOptions(maxMessageSizeBytes = maxMessageSizeBytes), handler)
}

/// As `startServer`, with explicit `WsServerOptions`.
@stable(since = "0.2")
pub func startServerWithOptions(
  host: in String,
  port: in Int,
  path: in String,
  options: in WsServerOptions,
  handler: in WsHandler,
): Result[NativeRegistry, WsError]
  requires: host.length > 0
  requires: port >= 1 and port <= 65535
  requires: path.startsWith("/")
{
  startOn(host, port, path, options, None, handler)
}

/// As `startServerWithOptions`, serving `wss`: every connection completes a
/// TLS handshake with `tls` (a certificate chain and private key, optional
/// minimum version and client-certificate policy: `Std.Tls`) before the
/// WebSocket upgrade. The configuration is validated before the port is
/// bound, so a bad one is `SERVER_START_FAILED`, not a listener that fails
/// every handshake. A handshake that fails or stalls past
/// `options.handshakeTimeoutMs` costs only its own connection.
///
/// Real on dotnet, the JVM and native, over `Std.TcpHost`'s TLS server path
/// (`SslStream`, `SSLSocket`, OpenSSL).
@stable(since = "0.4")
pub func startServerTls(
  host: in String,
  port: in Int,
  path: in String,
  tls: in Tls.TlsServerConfig,
  options: in WsServerOptions,
  handler: in WsHandler,
): Result[NativeRegistry, WsError]
  requires: host.length > 0
  requires: port >= 1 and port <= 65535
  requires: path.startsWith("/")
{
  startOn(host, port, path, options, Some(value = tls), handler)
}

func startOn(
  host: in String,
  port: in Int,
  path: in String,
  options: in WsServerOptions,
  tls: in Option[Tls.TlsServerConfig],
  handler: in WsHandler,
): Result[NativeRegistry, WsError] {
  val cbs = kernelCallbacks(path, handler)
  match kernelStartServer(host, port, path, options.maxMessageSizeBytes, options.allowedOrigins, options.sameHostPorts, kernelLimits(options), tls, cbs.onOpen, cbs.onMessage, cbs.onClose, cbs.onError) {
    case Ok(handle) -> Ok(NativeRegistry(registryHandle = handle))
    case Err(err) -> Err(WsError(message = err, code = "SERVER_START_FAILED", connectionId = ""))
  }
}

// The primitive callbacks the kernels take, adapting `handler`: the kernels
// exchange only strings and ints with this package (see the kernel-dispatch
// note above).
record KernelCallbacks {
  onOpen: (String, String, String, String, Map[String, String]) -> Unit
  onMessage: (String, String, String) -> Unit
  onClose: (String, Int, String) -> Unit
  onError: (String, String) -> Unit
}

func kernelCallbacks(path: in String, handler: in WsHandler): KernelCallbacks {
  val onOpenFn = { (connId: String, reqPath: String, reqQuery: String, remoteAddress: String, headers: Map[String, String]) ->
    val ctx = WsContext(
      connectionId = connId,
      path = reqPath,
      query = reqQuery,
      remoteAddress = remoteAddress,
      headers = headers
    )
    match handler.onOpen(ctx) {
      case Ok(_) -> ()
      case Err(e) -> handler.onError(ctx, e)
    }
  }
  val onMessageFn = { (connId: String, msgType: String, data: String) ->
    val ctx = WsContext(connectionId = connId, path = path, query = "", remoteAddress = "", headers = newMap())
    val msg = messageFromKernel(msgType, data)
    match handler.onMessage(ctx, msg) {
      case Ok(_) -> ()
      case Err(e) -> handler.onError(ctx, e)
    }
  }
  val onCloseFn = { (connId: String, code: Int, reason: String) ->
    val ctx = WsContext(connectionId = connId, path = path, query = "", remoteAddress = "", headers = newMap())
    handler.onClose(ctx, closeCodeFromInt(code))
  }
  val onErrorFn = { (connId: String, message: String) ->
    val ctx = WsContext(connectionId = connId, path = path, query = "", remoteAddress = "", headers = newMap())
    handler.onError(ctx, WsError(message = message, code = "TRANSPORT_ERROR", connectionId = connId))
  }
  KernelCallbacks(onOpen = onOpenFn, onMessage = onMessageFn, onClose = onCloseFn, onError = onErrorFn)
}

/// A WebSocket endpoint served on another HTTP server's port, from
/// `createEndpoint`.  Mount it on a `lyric-web` router with
/// `Web.addWebSocket`; push messages through `registry` exactly as with a
/// `startServer` registry.
@stable(since = "0.3")
pub record WsEndpoint {
  path: String
  registry: NativeRegistry
  allowedOrigins: slice[String]
  sameHostPorts: slice[Int]
}

/// Create a WebSocket endpoint for `path` with no listener of its own, to be
/// served on an HTTP server's port (`Web.addWebSocket`), so a page and its
/// socket share one origin.  `options` apply as in `startServerWithOptions`:
/// with a shared port the page and socket are same-origin, so the default
/// empty `allowedOrigins` already admits the page.  The endpoint accepts
/// connections once the HTTP server that mounts it is serving.
@stable(since = "0.3")
pub func createEndpoint(
  path: in String, options: in WsServerOptions, handler: in WsHandler
): Result[WsEndpoint, WsError]
  requires: path.startsWith("/")
{
  val cbs = kernelCallbacks(path, handler)
  match kernelCreateEndpoint(options.maxMessageSizeBytes, kernelLimits(options), cbs.onOpen, cbs.onMessage, cbs.onClose, cbs.onError) {
    case Ok(handle) -> Ok(
      WsEndpoint(
        path = path,
        registry = NativeRegistry(registryHandle = handle),
        allowedOrigins = options.allowedOrigins,
        sameHostPorts = options.sameHostPorts
      )
    )
    case Err(err) -> Err(WsError(message = err, code = "ENDPOINT_INIT_FAILED", connectionId = ""))
  }
}

/// Stop a server started by `startServer`/`startServerWithConfig`.
@stable(since = "0.1")
pub func stopServer(registry: in NativeRegistry): Result[Unit, WsError] {
  match kernelStopServer(registry.registryHandle) {
    case Ok(u) -> Ok(u)
    case Err(err) -> Err(WsError(message = err, code = "SERVER_STOP_FAILED", connectionId = ""))
  }
}

// ─── Convenience helpers ──────────────────────────────────────────────────────
/// Send a UTF-8 text message to a single connection.
@stable(since = "0.1")
pub func sendText(registry: in NativeRegistry, connectionId: in String, text: in String): Result[Unit, WsError] {
  val rh = registry.registryHandle
  match kernelSend(rh, connectionId, "text", text) {
    case Ok(u) -> Ok(u)
    case Err(err) -> Err(WsError(message = err, code = "SEND_FAILED", connectionId = connectionId))
  }
}

/// Broadcast a UTF-8 text message to all connected clients.
@stable(since = "0.1")
pub func broadcastText(registry: in NativeRegistry, text: in String): Result[Unit, WsError] {
  val rh = registry.registryHandle
  match kernelBroadcast(rh, "text", text) {
    case Ok(u) -> Ok(u)
    case Err(err) -> Err(WsError(message = err, code = "BROADCAST_FAILED", connectionId = ""))
  }
}

/// Close a connection with the normal close code 1000.
@stable(since = "0.1")
pub func closeConnection(registry: in NativeRegistry, connectionId: in String): Result[Unit, WsError] {
  val rh = registry.registryHandle
  match kernelClose(rh, connectionId, 1000, "") {
    case Ok(u) -> Ok(u)
    case Err(err) -> Err(WsError(message = err, code = "CLOSE_FAILED", connectionId = connectionId))
  }
}

/// Return the number of currently open connections.
@stable(since = "0.1")
pub func connectionCount(registry: in NativeRegistry): Int {
  val rh = registry.registryHandle
  return kernelConnectionCount(rh)
}

/// Return whether the given connection is currently open.
@stable(since = "0.1")
pub func isConnected(registry: in NativeRegistry, connectionId: in String): Bool {
  val rh = registry.registryHandle
  return kernelIsConnected(rh, connectionId)
}

/// Construct a Normal(1000) close code.
@stable(since = "0.1")
pub func makeCloseNormal(): WsCloseCode {
  return Normal(code = 1000)
}

/// Construct a GoingAway close code.
@stable(since = "0.1")
pub func makeCloseGoingAway(): WsCloseCode {
  return GoingAway
}

// ─── Private helpers ──────────────────────────────────────────────────────────
func messageTypeString(msg: in WsMessage): String {
  match msg {
    case Text(text) -> "text"
    case Binary(dataBase64) -> "binary"
    case Ping -> "ping"
    case Pong -> "pong"
    case Close(code, reason) -> "close"
  }
}

func messageDataString(msg: in WsMessage): String {
  match msg {
    case Text(text) -> text
    case Binary(dataBase64) -> dataBase64
    case Ping -> ""
    case Pong -> ""
    case Close(code, reason) -> reason
  }
}

func closeCodeToInt(code: in WsCloseCode): Int {
  match code {
    case Normal(c) -> c
    case GoingAway -> 1001
    case ProtocolError -> 1002
    case PolicyViolation -> 1008
    case InternalError -> 1011
  }
}

// Inverse of `messageTypeString`/`messageDataString` — reconstructs a
// `WsMessage` from the primitive (messageType, data) pair a kernel's
// `onMessage` callback delivers.
func messageFromKernel(msgType: in String, data: in String): WsMessage {
  if msgType == "text" {
    Text(text = data)
  } else if msgType == "binary" {
    Binary(dataBase64 = data)
  } else if msgType == "ping" {
    Ping
  } else if msgType == "pong" {
    Pong
  } else {
    Close(code = 1000, reason = data)
  }
}

// Inverse of `closeCodeToInt` for a kernel's `onClose` callback.  Any code
// outside the four named RFC 6455 constants round-trips through `Normal`
// (matching `closeCodeToInt`'s own `Normal(c) -> c` passthrough for custom
// application close codes, e.g. 4000+).
func closeCodeFromInt(code: in Int): WsCloseCode {
  if code == 1001 {
    GoingAway
  } else if code == 1002 {
    ProtocolError
  } else if code == 1008 {
    PolicyViolation
  } else if code == 1011 {
    InternalError
  } else {
    Normal(code = code)
  }
}
