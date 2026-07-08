//! Ws — WebSocket server library for Lyric.
//! Stability: @experimental — the connection lifecycle compiles and the WsAuth
//! aspect has tests.  `startServer` is backed by a real running server on
//! both targets: ASP.NET Core WebSockets is still path-finder-scope bookkeeping
//! only pending #778 (`Ws.Kernel.Net.startServer` returns `NOT_IMPLEMENTED`),
//! while Undertow on JVM is a real, tested end-to-end connect/send/receive/
//! close loop (see `Ws.Kernel.Jvm`'s header for its documented gaps:
//! fragmented multi-frame messages and automatic ping keepalives).  The
//! rate-limiter's burst budget is one-shot (does not refill; tracked in
//! issue #1178).
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
//!   // Start a real server bound to the handler (--target jvm today; see above)
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
package Ws

import Std.Core
import Std.Collections
import Ws.Kernel.Net as WsKernelNet
import Ws.Kernel.Jvm as WsKernelJvm

// Kernel boundary: every BCL / JDK interaction goes through the platform
// kernel (`Ws.Kernel.Net` on .NET, `Ws.Kernel.Jvm` on JVM), selected per
// function via the `kernelXxx` `@cfg`-paired wrappers below (mirrors
// `Auth`'s `Auth.Kernel.Net`/`Auth.Kernel.Jvm` dispatch).  This file is the
// public surface of the library; it must not declare its own `@axiom`
// stubs (doing so previously shadowed the kernel boundary and broke
// the trust-boundary audit — see lyric-lang #739).  The kernels only ever
// exchange primitive types (String/Int) with this file — never `WsHandler`/
// `WsContext`/`WsMessage` — so neither kernel needs to import `Ws` itself,
// avoiding an `Ws` <-> `Ws.Kernel.Jvm` import cycle.
@cfg(feature = "dotnet")
func kernelCreateRegistry(maxMessageSizeBytes: in Int, pingIntervalMs: in Int): Result[Int, String] {
  WsKernelNet.createRegistry(maxMessageSizeBytes, pingIntervalMs)
}

@cfg(feature = "jvm")
func kernelCreateRegistry(maxMessageSizeBytes: in Int, pingIntervalMs: in Int): Result[Int, String] {
  WsKernelJvm.createRegistry(maxMessageSizeBytes, pingIntervalMs)
}

@cfg(feature = "dotnet")
func kernelStartServer(
  host: in String,
  port: in Int,
  path: in String,
  maxMessageSizeBytes: in Int,
  onOpen: in (String, String, String, String) -> Unit,
  onMessage: in (String, String, String) -> Unit,
  onClose: in (String, Int, String) -> Unit,
  onError: in (String, String) -> Unit,
): Result[Int, String] {
  WsKernelNet.startServer(host, port, path, maxMessageSizeBytes, onOpen, onMessage, onClose, onError)
}

@cfg(feature = "jvm")
func kernelStartServer(
  host: in String,
  port: in Int,
  path: in String,
  maxMessageSizeBytes: in Int,
  onOpen: in (String, String, String, String) -> Unit,
  onMessage: in (String, String, String) -> Unit,
  onClose: in (String, Int, String) -> Unit,
  onError: in (String, String) -> Unit,
): Result[Int, String] {
  WsKernelJvm.startServer(host, port, path, maxMessageSizeBytes, onOpen, onMessage, onClose, onError)
}

@cfg(feature = "dotnet")
func kernelStopServer(registryHandle: in Int): Result[Unit, String] {
  WsKernelNet.stopServer(registryHandle)
}

@cfg(feature = "jvm")
func kernelStopServer(registryHandle: in Int): Result[Unit, String] {
  WsKernelJvm.stopServer(registryHandle)
}

@cfg(feature = "dotnet")
func kernelSend(registryHandle: in Int, connectionId: in String, messageType: in String, data: in String): Result[Unit, String] {
  WsKernelNet.send(registryHandle, connectionId, messageType, data)
}

@cfg(feature = "jvm")
func kernelSend(registryHandle: in Int, connectionId: in String, messageType: in String, data: in String): Result[Unit, String] {
  WsKernelJvm.send(registryHandle, connectionId, messageType, data)
}

@cfg(feature = "dotnet")
func kernelBroadcast(registryHandle: in Int, messageType: in String, data: in String): Result[Unit, String] {
  WsKernelNet.broadcast(registryHandle, messageType, data)
}

@cfg(feature = "jvm")
func kernelBroadcast(registryHandle: in Int, messageType: in String, data: in String): Result[Unit, String] {
  WsKernelJvm.broadcast(registryHandle, messageType, data)
}

@cfg(feature = "dotnet")
func kernelClose(registryHandle: in Int, connectionId: in String, code: in Int, reason: in String): Result[Unit, String] {
  WsKernelNet.close(registryHandle, connectionId, code, reason)
}

@cfg(feature = "jvm")
func kernelClose(registryHandle: in Int, connectionId: in String, code: in Int, reason: in String): Result[Unit, String] {
  WsKernelJvm.close(registryHandle, connectionId, code, reason)
}

@cfg(feature = "dotnet")
func kernelConnectionCount(registryHandle: in Int): Int {
  WsKernelNet.connectionCount(registryHandle)
}

@cfg(feature = "jvm")
func kernelConnectionCount(registryHandle: in Int): Int {
  WsKernelJvm.connectionCount(registryHandle)
}

@cfg(feature = "dotnet")
func kernelIsConnected(registryHandle: in Int, connectionId: in String): Bool {
  WsKernelNet.isConnected(registryHandle, connectionId)
}

@cfg(feature = "jvm")
func kernelIsConnected(registryHandle: in Int, connectionId: in String): Bool {
  WsKernelJvm.isConnected(registryHandle, connectionId)
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
/// Start a real WebSocket server bound to `handler`, listening on
/// `host:port` and upgrading exactly `path` to WebSocket.  Non-blocking:
/// returns once the server is listening.  Use the returned registry to push
/// messages from outside the handler callbacks; call `stopServer` to shut
/// down.  Uses the default 65536-byte max message size — see
/// `startServerWithConfig` to override it.
///
/// See the module header for per-target status: real end-to-end on
/// `--target jvm` (Undertow); `Err(WsError(code = "SERVER_START_FAILED"))`
/// on `--target dotnet` pending #778.
@stable(since = "0.1")
pub func startServer(host: in String, port: in Int, path: in String, handler: in WsHandler): Result[NativeRegistry, WsError] {
  startServerWithConfig(host, port, path, 65536, handler)
}

/// As `startServer`, with an explicit max message size in bytes.
@stable(since = "0.1")
pub func startServerWithConfig(
  host: in String,
  port: in Int,
  path: in String,
  maxMessageSizeBytes: in Int,
  handler: in WsHandler,
): Result[NativeRegistry, WsError] {
  val onOpenFn = { (connId: String, reqPath: String, reqQuery: String, remoteAddress: String) ->
    val ctx = WsContext(connectionId = connId, path = reqPath, query = reqQuery, remoteAddress = remoteAddress, headers = newMap())
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
  match kernelStartServer(host, port, path, maxMessageSizeBytes, onOpenFn, onMessageFn, onCloseFn, onErrorFn) {
    case Ok(handle) -> Ok(NativeRegistry(registryHandle = handle))
    case Err(err) -> Err(WsError(message = err, code = "SERVER_START_FAILED", connectionId = ""))
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
