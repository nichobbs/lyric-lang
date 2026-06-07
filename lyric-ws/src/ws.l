//! Ws — WebSocket server library for Lyric.
//! Stability: @experimental — the connection lifecycle compiles and the WsAuth
//! aspect has tests, but the rate-limiter's burst budget is one-shot (does not
//! refill; tracked in issue #1178) and the end-to-end loop has not been exercised
//! against a real WebSocket client in CI.
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
//!   // Create a registry and start serving
//!   match Ws.createRegistry() {
//!     case Ok(registry) -> ...
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
import Ws.Kernel.Net as WsKernel

// Kernel boundary: every BCL / JDK interaction goes through `WsKernel`
// (`Ws.Kernel.Net` on .NET, `Ws.Kernel.Jvm` on JVM).  This file is the
// public surface of the library; it must not declare its own `@axiom`
// stubs (doing so previously shadowed the kernel boundary and broke
// the trust-boundary audit — see lyric-lang #739).
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
    match WsKernel.send(rh, connectionId, msgType, msgData) {
      case Ok(u) -> Ok(u)
      case Err(err) -> Err(WsError(message = err, code = "SEND_FAILED", connectionId = connectionId))
    }
  }

  func broadcast(msg: in WsMessage): Result[Unit, WsError] {
    val msgType = messageTypeString(msg)
    val msgData = messageDataString(msg)
    val rh = self.registryHandle
    match WsKernel.broadcast(rh, msgType, msgData) {
      case Ok(u) -> Ok(u)
      case Err(err) -> Err(WsError(message = err, code = "BROADCAST_FAILED", connectionId = ""))
    }
  }

  func close(connectionId: in String, code: in WsCloseCode, reason: in String): Result[Unit, WsError] {
    val codeInt = closeCodeToInt(code)
    val rh = self.registryHandle
    match WsKernel.close(rh, connectionId, codeInt, reason) {
      case Ok(u) -> Ok(u)
      case Err(err) -> Err(WsError(message = err, code = "CLOSE_FAILED", connectionId = connectionId))
    }
  }

  func connectionCount(): Int {
    val rh = self.registryHandle
    return WsKernel.connectionCount(rh)
  }

  func isConnected(connectionId: in String): Bool {
    val rh = self.registryHandle
    return WsKernel.isConnected(rh, connectionId)
  }
}

// ─── Factory ──────────────────────────────────────────────────────────────────
/// Create a kernel-backed connection registry.
/// The registry manages WebSocket connection lifecycle.
@stable(since = "0.1")
pub func createRegistry(): Result[NativeRegistry, WsError] {
  match WsKernel.createRegistry(65536, 30000) {
    case Ok(handle) -> Ok(NativeRegistry(registryHandle = handle))
    case Err(err) -> Err(WsError(message = err, code = "REGISTRY_INIT_FAILED", connectionId = ""))
  }
}

// ─── Convenience helpers ──────────────────────────────────────────────────────
/// Send a UTF-8 text message to a single connection.
@stable(since = "0.1")
pub func sendText(registry: in NativeRegistry, connectionId: in String, text: in String): Result[Unit, WsError] {
  val rh = registry.registryHandle
  match WsKernel.send(rh, connectionId, "text", text) {
    case Ok(u) -> Ok(u)
    case Err(err) -> Err(WsError(message = err, code = "SEND_FAILED", connectionId = connectionId))
  }
}

/// Broadcast a UTF-8 text message to all connected clients.
@stable(since = "0.1")
pub func broadcastText(registry: in NativeRegistry, text: in String): Result[Unit, WsError] {
  val rh = registry.registryHandle
  match WsKernel.broadcast(rh, "text", text) {
    case Ok(u) -> Ok(u)
    case Err(err) -> Err(WsError(message = err, code = "BROADCAST_FAILED", connectionId = ""))
  }
}

/// Close a connection with the normal close code 1000.
@stable(since = "0.1")
pub func closeConnection(registry: in NativeRegistry, connectionId: in String): Result[Unit, WsError] {
  val rh = registry.registryHandle
  match WsKernel.close(rh, connectionId, 1000, "") {
    case Ok(u) -> Ok(u)
    case Err(err) -> Err(WsError(message = err, code = "CLOSE_FAILED", connectionId = connectionId))
  }
}

/// Return the number of currently open connections.
@stable(since = "0.1")
pub func connectionCount(registry: in NativeRegistry): Int {
  val rh = registry.registryHandle
  return WsKernel.connectionCount(rh)
}

/// Return whether the given connection is currently open.
@stable(since = "0.1")
pub func isConnected(registry: in NativeRegistry, connectionId: in String): Bool {
  val rh = registry.registryHandle
  return WsKernel.isConnected(rh, connectionId)
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
