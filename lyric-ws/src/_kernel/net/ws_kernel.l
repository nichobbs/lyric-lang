/// Ws.Kernel.Net — ASP.NET Core WebSockets extern boundary.
///
/// Phase 6 of #733: in-process connection registry + sliding-window
/// rate limiter functional via `Lyric.Ws.RegistryHost` and
/// `Lyric.Ws.RateLimitHost`.  Real ASP.NET Core WebSocket integration
/// (HTTP upgrade, MessageReceived loop, Kestrel binding) is tracked
/// under #778 as a follow-up — that path needs the lyric-web Kestrel
/// shim to land first (Phase 8).
///
/// The path-finder registry tracks connection IDs and supports send /
/// broadcast / close / connectionCount / isConnected at the bookkeeping
/// level; `send` / `broadcast` buffer frames in per-connection queues
/// for test inspection.  Real ASP.NET socket dispatch is a future
/// integration.
///
/// Only active when compiled with feature = "dotnet".
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Ws.Kernel.Net

import Std.Core

// ─── Registry (Phase 6 functional path) ──────────────────────────────────────

@axiom("Lyric.Ws.RegistryHost.createRegistry — allocates a per-process ConcurrentDictionary-backed connection registry")
@externTarget("Lyric.Ws.RegistryHost.createRegistry")
@stable(since="0.1")
pub func createRegistry(maxMessageSizeBytes: in Int, pingIntervalMs: in Int): Result[Int, String]
  requires: maxMessageSizeBytes >= 1024
  requires: pingIntervalMs >= 0
  = ()

@axiom("Lyric.Ws.RegistryHost.send — buffers a (messageType, data) pair into the connection's OutBuf (real socket dispatch is a follow-up under #778)")
@externTarget("Lyric.Ws.RegistryHost.send")
@stable(since="0.1")
pub func send(registryHandle: in Int, connectionId: in String, messageType: in String, data: in String): Result[Unit, String]
  requires: connectionId.length > 0
  requires: messageType.length > 0
  = ()

@axiom("Lyric.Ws.RegistryHost.broadcast — buffers (messageType, data) into every open connection's OutBuf")
@externTarget("Lyric.Ws.RegistryHost.broadcast")
@stable(since="0.1")
pub func broadcast(registryHandle: in Int, messageType: in String, data: in String): Result[Unit, String]
  requires: messageType.length > 0
  = ()

@axiom("Lyric.Ws.RegistryHost.close — marks the connection as closed and queues an RFC 6455 close frame (idempotent)")
@externTarget("Lyric.Ws.RegistryHost.close")
@stable(since="0.1")
pub func close(registryHandle: in Int, connectionId: in String, code: in Int, reason: in String): Result[Unit, String]
  requires: connectionId.length > 0
  = ()

@axiom("Lyric.Ws.RegistryHost.connectionCount — count of connections with Open = true")
@externTarget("Lyric.Ws.RegistryHost.connectionCount")
@stable(since="0.1")
pub func connectionCount(registryHandle: in Int): Int = ()

@axiom("Lyric.Ws.RegistryHost.isConnected — whether the connection ID is registered and Open")
@externTarget("Lyric.Ws.RegistryHost.isConnected")
@stable(since="0.1")
pub func isConnected(registryHandle: in Int, connectionId: in String): Bool
  requires: connectionId.length > 0
  = ()

// ─── Sliding-window rate limit ────────────────────────────────────────────────

@axiom("Lyric.Ws.RateLimitHost.checkRateLimit — per-key 60s sliding window + burst budget; state is per-process")
@externTarget("Lyric.Ws.RateLimitHost.checkRateLimit")
@stable(since="0.1")
pub func checkRateLimit(key: in String, messagesPerMinute: in Int, burstSize: in Int): Bool
  requires: key.length > 0
  requires: messagesPerMinute > 0
  requires: burstSize > 0
  = ()
