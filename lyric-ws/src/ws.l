/// Ws — WebSocket server library for Lyric.
///
/// Provides the full connection lifecycle for WebSocket servers:
/// connection context, message types, a handler interface for
/// application logic, and a registry interface for sending to
/// connected clients.
///
/// Typical usage:
///
///   import Ws
///
///   // Implement WsHandler for application logic
///   record MyHandler {}
///   impl WsHandler for MyHandler {
///     func onOpen(ctx: in WsContext): Result[Unit, WsError] { ... }
///     func onMessage(ctx: in WsContext, msg: in WsMessage): Result[Unit, WsError] { ... }
///     func onClose(ctx: in WsContext, code: in WsCloseCode): Unit { ... }
///     func onError(ctx: in WsContext, error: in WsError): Unit { ... }
///   }
///
///   // Create a registry and start serving
///   match Ws.createRegistry() {
///     case Ok(registry) -> ...
///     case Err(e) -> ...
///   }
///
/// Runtime config env vars (LYRIC_CONFIG_WS_SERVER_*):
///   LYRIC_CONFIG_WS_SERVER_PATH                — WebSocket upgrade path (default: /ws)
///   LYRIC_CONFIG_WS_SERVER_MAXMESSAGESIZEBYTES — max frame size in bytes (default: 65536)
///   LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS      — ping interval in milliseconds (default: 30000)
///   LYRIC_CONFIG_WS_SERVER_HANDSHAKETIMEOUTMS  — upgrade handshake timeout (default: 10000)
///   LYRIC_CONFIG_WS_AUTH_ENABLED               — enable JWT gate on upgrade (default: true)
///   LYRIC_CONFIG_WS_AUTH_JWTSECRET             — HMAC-SHA256 secret for JWT (required when auth enabled)
///   LYRIC_CONFIG_WS_AUTH_ISSUER                — expected iss claim (default: "")
///   LYRIC_CONFIG_WS_AUTH_AUDIENCE              — expected aud claim (default: "")

@runtime_checked
package Ws

import Std.Core
import Std.Collections
import Auth
import Ws.Kernel.Net

// ─── Connection identity ──────────────────────────────────────────────────────

/// Opaque identifier for a single WebSocket connection.
/// Assigned by the kernel at upgrade time and stable until close.
@stable(since="0.1")
pub type WsConnectionId = String

// ─── Close codes ─────────────────────────────────────────────────────────────

/// RFC 6455 close codes sent in Close frames.
@stable(since="0.1")
pub enum WsCloseCode {
  case Normal(code: Int)
  case GoingAway
  case ProtocolError
  case PolicyViolation
  case InternalError
}

// ─── Message types ────────────────────────────────────────────────────────────

/// A WebSocket frame payload.
@stable(since="0.1")
pub enum WsMessage {
  /// UTF-8 text frame.
  case Text(text: String)
  /// Binary frame with Base64-encoded payload.
  case Binary(dataBase64: String)
  /// Ping control frame.
  case Ping
  /// Pong control frame.
  case Pong
  /// Close frame with a close code and human-readable reason.
  case Close(code: WsCloseCode, reason: String)
}

// ─── Error ────────────────────────────────────────────────────────────────────

/// Error produced by WebSocket operations.
@stable(since="0.1")
pub record WsError {
  message:      String
  code:         String
  connectionId: WsConnectionId
}

// ─── Connection context ───────────────────────────────────────────────────────

/// Snapshot of a WebSocket connection's metadata, available in every callback.
@stable(since="0.1")
pub record WsContext {
  connectionId:  WsConnectionId
  path:          String
  query:         String
  remoteAddress: String
  headers:       Map[String, String]
}

// ─── Handler interface ────────────────────────────────────────────────────────

/// Application-level WebSocket handler.  Implement this interface to receive
/// connection lifecycle and message events.  Return Err to signal that a
/// problem occurred; the kernel will close the connection with InternalError.
@stable(since="0.1")
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
@stable(since="0.1")
pub interface WsRegistry {
  /// Send a message to a single connection.
  func send(connectionId: in WsConnectionId, msg: in WsMessage): Result[Unit, WsError]
    requires: connectionId.length > 0

  /// Broadcast a message to all currently connected clients.
  func broadcast(msg: in WsMessage): Result[Unit, WsError]

  /// Close a connection with the given code and reason.
  func close(connectionId: in WsConnectionId, code: in WsCloseCode, reason: in String): Result[Unit, WsError]
    requires: connectionId.length > 0

  /// Return the number of currently open connections.
  func connectionCount(): Int

  /// Return whether the given connection is currently open.
  func isConnected(connectionId: in WsConnectionId): Bool
    requires: connectionId.length > 0
}

// ─── Native registry ──────────────────────────────────────────────────────────

/// Kernel-backed registry implementation.  Obtain via `createRegistry()`.
@stable(since="0.1")
pub record NativeRegistry {
  registryHandle: Int
}

impl WsRegistry for NativeRegistry {
  func send(connectionId: in WsConnectionId, msg: in WsMessage): Result[Unit, WsError] {
    val msgType = messageTypeString(msg)
    val msgData = messageDataString(msg)
    match Ws.Kernel.Net.send(registryHandle, connectionId, msgType, msgData) {
      case Ok(u)    -> Ok(u)
      case Err(err) -> Err(WsError(message = err, code = "SEND_FAILED", connectionId = connectionId))
    }
  }

  func broadcast(msg: in WsMessage): Result[Unit, WsError] {
    val msgType = messageTypeString(msg)
    val msgData = messageDataString(msg)
    match Ws.Kernel.Net.broadcast(registryHandle, msgType, msgData) {
      case Ok(u)    -> Ok(u)
      case Err(err) -> Err(WsError(message = err, code = "BROADCAST_FAILED", connectionId = ""))
    }
  }

  func close(connectionId: in WsConnectionId, code: in WsCloseCode, reason: in String): Result[Unit, WsError] {
    val codeInt = closeCodeToInt(code)
    match Ws.Kernel.Net.close(registryHandle, connectionId, codeInt, reason) {
      case Ok(u)    -> Ok(u)
      case Err(err) -> Err(WsError(message = err, code = "CLOSE_FAILED", connectionId = connectionId))
    }
  }

  func connectionCount(): Int {
    return Ws.Kernel.Net.connectionCount(registryHandle)
  }

  func isConnected(connectionId: in WsConnectionId): Bool {
    return Ws.Kernel.Net.isConnected(registryHandle, connectionId)
  }
}

// ─── Runtime config ───────────────────────────────────────────────────────────

/// WebSocket server binding and tuning.
config Server {
  path:                 String                      = "/ws"
  maxMessageSizeBytes:  Int range 1024..=10485760   = 65536
  pingIntervalMs:       Int range 0..=300000        = 30000
  handshakeTimeoutMs:   Int range 1000..=30000      = 10000
}

/// JWT-based authentication applied at upgrade time.
config WsAuthConfig {
  enabled:    Bool   = true
  @sensitive
  jwtSecret:  String = ""
  issuer:     String = ""
  audience:   String = ""
}

// ─── Factory ──────────────────────────────────────────────────────────────────

/// Create a kernel-backed connection registry using the Server config.
@stable(since="0.1")
pub func createRegistry(): Result[WsRegistry, WsError] {
  match Ws.Kernel.Net.createRegistry(Server.maxMessageSizeBytes, Server.pingIntervalMs) {
    case Ok(handle) -> Ok(NativeRegistry(registryHandle = handle))
    case Err(err)   -> Err(WsError(message = err, code = "REGISTRY_INIT_FAILED", connectionId = ""))
  }
}

// ─── Convenience helpers ──────────────────────────────────────────────────────

/// Send a UTF-8 text message to a single connection.
@stable(since="0.1")
pub func send(registry: in WsRegistry, connectionId: in WsConnectionId, text: in String): Result[Unit, WsError]
  requires: connectionId.length > 0
{
  return registry.send(connectionId, WsMessage.Text(text = text))
}

/// Broadcast a UTF-8 text message to all connected clients.
@stable(since="0.1")
pub func broadcast(registry: in WsRegistry, text: in String): Result[Unit, WsError] {
  return registry.broadcast(WsMessage.Text(text = text))
}

/// Close a connection with the normal close code 1000.
@stable(since="0.1")
pub func close(registry: in WsRegistry, connectionId: in WsConnectionId): Result[Unit, WsError]
  requires: connectionId.length > 0
{
  return registry.close(connectionId, WsCloseCode.Normal(code = 1000), "")
}

/// Return the number of currently open connections.
@stable(since="0.1")
pub func connectionCount(registry: in WsRegistry): Int {
  return registry.connectionCount()
}

/// Return whether the given connection is currently open.
@stable(since="0.1")
pub func isConnected(registry: in WsRegistry, connectionId: in WsConnectionId): Bool
  requires: connectionId.length > 0
{
  return registry.isConnected(connectionId)
}

/// Construct a Normal(1000) close code.
@stable(since="0.1")
pub func makeCloseNormal(): WsCloseCode {
  return WsCloseCode.Normal(code = 1000)
}

/// Construct a GoingAway close code.
@stable(since="0.1")
pub func makeCloseGoingAway(): WsCloseCode {
  return WsCloseCode.GoingAway
}

// ─── Private helpers ──────────────────────────────────────────────────────────

func messageTypeString(msg: in WsMessage): String {
  match msg {
    case Text(_)      -> "text"
    case Binary(_)    -> "binary"
    case Ping         -> "ping"
    case Pong         -> "pong"
    case Close(_, _)  -> "close"
  }
}

func messageDataString(msg: in WsMessage): String {
  match msg {
    case Text(text)         -> text
    case Binary(dataBase64) -> dataBase64
    case Ping               -> ""
    case Pong               -> ""
    case Close(_, reason)   -> reason
  }
}

func closeCodeToInt(code: in WsCloseCode): Int {
  match code {
    case Normal(c)      -> c
    case GoingAway      -> 1001
    case ProtocolError  -> 1002
    case PolicyViolation -> 1008
    case InternalError  -> 1011
  }
}
