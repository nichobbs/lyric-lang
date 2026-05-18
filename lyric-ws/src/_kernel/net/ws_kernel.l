// Ws.Kernel.Net — ASP.NET Core WebSockets extern boundary.
//
// Bridges the Ws package to the ASP.NET Core WebSocket infrastructure:
//   - createRegistry()   — allocates a connection registry and returns its handle
//   - send()             — send a typed frame to one connection
//   - broadcast()        — send a typed frame to all connections
//   - close()            — close a connection with an RFC 6455 code
//   - connectionCount()  — number of open connections
//   - isConnected()      — query whether a specific connection is open
//   - checkRateLimit()   — sliding-window rate limiter keyed by arbitrary string
//
// Only active when compiled with feature = "dotnet".
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Ws.Kernel.Net

import Std.Core

// ─── WebSocket server ─────────────────────────────────────────────────────────

@axiom("ASP.NET Core WebSockets (Microsoft.AspNetCore.WebSockets)")
extern package Microsoft.AspNetCore.WebSockets {
  /// Allocate a connection registry.  Returns an opaque integer handle that
  /// identifies the registry in subsequent calls.
  pub func createRegistry(maxMessageSizeBytes: Int, pingIntervalMs: Int): Result[Int, String]
    requires: maxMessageSizeBytes >= 1024
    requires: pingIntervalMs >= 0

  /// Send a WebSocket frame to a single connection.
  /// `messageType` is one of: "text", "binary", "ping", "pong", "close".
  /// `data` is the frame payload (UTF-8 string for text, Base64 for binary,
  /// empty for ping/pong, the reason phrase for close).
  pub func send(registryHandle: Int, connectionId: String, messageType: String, data: String): Result[Unit, String]
    requires: connectionId.length > 0
    requires: messageType.length > 0

  /// Broadcast a WebSocket frame to all currently open connections.
  pub func broadcast(registryHandle: Int, messageType: String, data: String): Result[Unit, String]
    requires: messageType.length > 0

  /// Close a connection with an RFC 6455 numeric close code and reason.
  pub func close(registryHandle: Int, connectionId: String, code: Int, reason: String): Result[Unit, String]
    requires: connectionId.length > 0

  /// Return the number of currently open connections in this registry.
  pub func connectionCount(registryHandle: Int): Int

  /// Return whether the given connection is currently open.
  pub func isConnected(registryHandle: Int, connectionId: String): Bool
    requires: connectionId.length > 0
}

// ─── Rate limiting ────────────────────────────────────────────────────────────

@axiom("In-process sliding-window rate limiter (System.Threading.RateLimiting)")
extern package System.Threading.RateLimiting {
  /// Check whether a call identified by `key` is within the rate limit.
  /// Returns true (allow) or false (deny).
  /// State is per-process and per-key; resets on process restart.
  pub func checkRateLimit(key: String, messagesPerMinute: Int, burstSize: Int): Bool
    requires: key.length > 0
    requires: messagesPerMinute > 0
    requires: burstSize > 0
}

// ─── Re-export wrappers ───────────────────────────────────────────────────────

/// Allocate a kernel connection registry.
@stable(since="0.1")
pub func createRegistry(maxMessageSizeBytes: in Int, pingIntervalMs: in Int): Result[Int, String] {
  return Microsoft.AspNetCore.WebSockets.createRegistry(maxMessageSizeBytes, pingIntervalMs)
}

/// Send a typed WebSocket frame to a single connection.
@stable(since="0.1")
pub func send(registryHandle: in Int, connectionId: in String, messageType: in String, data: in String): Result[Unit, String]
  requires: connectionId.length > 0
  requires: messageType.length > 0
{
  return Microsoft.AspNetCore.WebSockets.send(registryHandle, connectionId, messageType, data)
}

/// Broadcast a typed WebSocket frame to all open connections.
@stable(since="0.1")
pub func broadcast(registryHandle: in Int, messageType: in String, data: in String): Result[Unit, String]
  requires: messageType.length > 0
{
  return Microsoft.AspNetCore.WebSockets.broadcast(registryHandle, messageType, data)
}

/// Close a connection with an RFC 6455 numeric close code.
@stable(since="0.1")
pub func close(registryHandle: in Int, connectionId: in String, code: in Int, reason: in String): Result[Unit, String]
  requires: connectionId.length > 0
{
  return Microsoft.AspNetCore.WebSockets.close(registryHandle, connectionId, code, reason)
}

/// Return the number of currently open connections.
@stable(since="0.1")
pub func connectionCount(registryHandle: in Int): Int {
  return Microsoft.AspNetCore.WebSockets.connectionCount(registryHandle)
}

/// Return whether the given connection is currently open.
@stable(since="0.1")
pub func isConnected(registryHandle: in Int, connectionId: in String): Bool
  requires: connectionId.length > 0
{
  return Microsoft.AspNetCore.WebSockets.isConnected(registryHandle, connectionId)
}

/// Check whether a key is within the per-minute rate limit.
@stable(since="0.1")
pub func checkRateLimit(key: in String, messagesPerMinute: in Int, burstSize: in Int): Bool
  requires: key.length > 0
  requires: messagesPerMinute > 0
  requires: burstSize > 0
{
  return System.Threading.RateLimiting.checkRateLimit(key, messagesPerMinute, burstSize)
}
