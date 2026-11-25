# lyric-ws

**Stability:** `stable`

WebSocket server with pluggable backends and aspect-based security.

## Platform parity

`Ws.startServer` is one pure-Lyric RFC 6455 server, `Ws.Kernel.Net`, on every target. It sits on the `Std.TcpHost` transport kernel, the seam `Std.HttpServer` and `Std.HttpEngine` use (docs/61 phase 3.3, docs/62 section 6, docs/73 slice S7a, D787). No new NuGet or Maven dependency; not ASP.NET Core WebSockets.

| Feature flag | `Ws.startServer` | Per-target primitives (`src/_kernel/<dir>/ws_prims.l`) | Tested in CI |
|--------------|------------------|--------------------------------------------------------|--------------|
| `dotnet`     | `Ws.Kernel.Net` over `Std.TcpHost` | `Monitor` locks, `Task.Run` background tasks, `ConcurrentDictionary`; the threadpool minimum is raised so a connection burst is not throttled (#9335) | `lyric test --manifest lyric-ws/lyric.toml`: frame, handshake, aspect and loopback suites |
| `jvm`        | the same `Ws.Kernel.Net` | `ReentrantLock` locks (never `synchronized`, which pins a virtual thread's carrier), virtual-thread background tasks, a lock-guarded map | the same five suites through `scripts/ci/jvm-ecosystem-suites.sh` |
| `native`     | the same `Ws.Kernel.Net` | pthread mutex pool, detached pthreads, a lock-guarded map | frame, handshake and loopback suites through `scripts/ci/native-web-smoke.sh` (the aspect-weaving suite does not build on native, `A0045`, #3498) |

All three targets share the handshake parser and `Sec-WebSocket-Accept` derivation (`Ws.Handshake`), the frame codec (`Ws.Frame`: masking, control frames, **fragmented multi-frame message reassembly**, UTF-8 validation, size cap), **automatic ping-interval keepalive**, the Origin check, and the `onError` isolation of a failing handler. Concurrency: a background task runs the accept loop, and each connection gets a read-loop task plus a maintenance task (keepalive pings, the idle timeout and the write watchdog, docs/73 S8) and, while frames are waiting to be written, a short-lived drain task; `pingIntervalMs` is read from `LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS` rather than threaded through `startServer`'s parameters (see `Ws.Kernel.Net`'s module header).

The loopback suite (`tests/ws_e2e_tests.l`, `Ws.WsE2eTests`) dials the real server over `Std.TcpHost` with a hand-written RFC 6455 client: handshake, text and binary echo, a fragmented message, ping and pong, close handshake, registry state, `send` and `broadcast` from outside callbacks, the Origin policy (same-origin, cross-origin, `allowedOrigins`), a throwing handler, 250 simultaneous connections, and the routing of endpoint and server registries. A throwing handler cannot be caught on native (no unwinding, D-N-003), so that one check is a no-op there.

### Limits, slow consumers and wss (docs/73 S8, D792 to D794)

Every limit is a field of `WsServerOptions` with a default, so existing callers compile and behave as before except for the bounds the defaults now enforce. A value of `0` turns a bound off, except `maxConnections`.

| Option | Default | What it bounds |
|--------|---------|----------------|
| `maxOutboundBytes` | 1 MiB (at least 1024) | Bytes queued for one connection. `send` and `broadcast` return once a frame is queued (`Ok` means queued, not delivered). A connection whose backlog would pass the bound is dropped: `send` returns `Err` ("slow consumer: ..."), `onError` is told, `onClose` reports 1008 and the socket is shut down. The first frame is always accepted, so a single message larger than the bound is not refused. Ping, pong and close frames are exempt. |
| `writeTimeoutMs` | 10 000 | A write that makes no progress for this long (the peer stopped reading but the queue still has room) ends the connection the same way. Enforced by the per-connection maintenance task, so it is checked every quarter of the shortest timeout (at most one second late), on every target. |
| `idleTimeoutMs` | 90 000 | Nothing received for this long, a Pong to the keepalive Ping included, starts the close handshake with 1001; a peer that does not answer the Close within 5 s is shut down. With the default 30 s ping interval a healthy client is never idle. Set it to `0` if you also disable pings (`LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS=0`) and have quiet clients. |
| `maxConnections` | 0 = per target: 10 000 on the JVM, 1 000 on dotnet and native (`Std.HttpServerHost.defaultMaxConnections`) | Connections admitted at once, handshakes included. One more is answered `503 Service Unavailable` (a `wss` listener closes it without an answer) and is not counted by `connectionCount`. |
| `handshakeTimeoutMs` | 10 000 | The TLS handshake and the HTTP upgrade. A peer that connects and sends nothing is closed and holds its slot only that long. |

`broadcast` encodes the frame once and queues it for every connection without writing to any socket, so one slow consumer delays no one; it returns `Err` with the first failure (a connection that closed meanwhile, or a slow consumer it dropped) after attempting all of them. The same bounds apply to `Web.addWebSocket` endpoints (`createEndpoint`), where `handshakeTimeoutMs` is the HTTP server's.

**wss.** `Ws.startServerTls(host, port, path, tls, options, handler)` takes a `Std.Tls.TlsServerConfig` (certificate chain and key, minimum TLS version, optional client CA and `requireClientCert` for mutual TLS). The configuration is validated before the port is bound, and each connection's handshake runs on its own task, so a stalled one costs only itself. It runs over `Std.TcpHost`'s TLS server path on dotnet (`SslStream`), the JVM (`SSLSocket`) and native (OpenSSL). Tests: `tests/ws_hardening_tests.l` drives it through `Std.Http`'s TLS client on every target (TLS terminates, the WebSocket server answers through it, mutual TLS refuses and admits, a bad configuration is refused, a silent peer is cut off) and exchanges WebSocket frames over TLS with `Std.TcpHost`'s client TLS connect (`hostConnectTls`, on every target since D799; run on dotnet and native, not run on the JVM here because the package's JVM build needs the Undertow jars).

### Known gaps

- Autobahn (RFC 6455 conformance) is not run in CI. It needs Docker, which the development container lacks, and the server answers a client Ping only through the handler (the kernel delivers `Ping` to `onMessage` and does not reply, so Autobahn's section 2 cases would fail). See D795.
- No `permessage-deflate` (RFC 7692), by decision (D795), and no subprotocol negotiation.
- `[package] targets` is not declared. Whether to claim native depends on the aspect-template limit above.

## Packages

| Package | Purpose |
|---|---|
| `Ws` | Core types, `WsHandler`/`WsRegistry` interfaces, and public API |
| `Ws.Frame` | Pure-Lyric RFC 6455 frame codec (target-independent) |
| `Ws.Handshake` | Pure-Lyric HTTP/1.1 upgrade-handshake parser + `Sec-WebSocket-Accept` derivation (target-independent) |
| `Ws.Aspects` | Reusable aspect templates: `WsAuth` and `WsRateLimit` |

## Serving on an HTTP server's port

`Ws.startServer*` binds a listener of its own. To serve a socket on the same
port as a `lyric-web` router (one origin for the page and its socket), create
a listener-less endpoint and mount it:

```lyric
val endpoint = Ws.createEndpoint("/live", Ws.WsServerOptions(), MyHandler())?
val router = Web.addWebSocket(Web.create(), endpoint)
```

`endpoint.registry` is a `NativeRegistry` like `startServer`'s. On dotnet
the HTTP server hands the connection to `Ws.Kernel.Net.adoptConnection`; on
the JVM and native it does so through `Std.HttpServer.takeConnection`.
Both apply the same `WsServerOptions` Origin check as `startServer`.

## Quick start

```lyric
import Ws

val registry = Ws.createRegistry()

// Register a handler for a route
Ws.register(registry, "/chat", func(ctx: in WsContext): Unit {
  match Ws.receive(ctx) {
    case Some(msg) -> {
      println("Received: " + msg.text)
      Ws.broadcast(registry, msg.text)
    }
    case None -> println("connection closed")
  }
})

// In your web server, bind the registry
// Example with lyric-web:
// import Web
// Web.route("ws", "/ws/*", websocketHandler(registry))
```

## Backends

`Ws.startServer` is the pure-Lyric RFC 6455 server over `Std.TcpHost` (`Ws.Kernel.Net`) on dotnet, the JVM and native. See "Platform parity" above.

## Core types and functions

### WsHandler interface

```lyric
pub interface WsHandler {
  func handle(context: in WsContext): Unit
}
```

### WsRegistry interface

```lyric
pub interface WsRegistry {
  func register(route: in String, handler: in WsHandler): Unit
  func broadcast(message: in String): Unit
  func send(connectionId: in String, message: in String): Result[Unit, WsError]
  func close(connectionId: in String): Unit
}
```

### WsContext type

```lyric
pub record WsContext {
  connectionId: String
  path: String
  query: String
  remoteAddress: String
  headers: Map[String, String]   // upgrade request headers, lower-cased names
}
```

`headers` holds the upgrade request's headers in the `onOpen` context; a
repeated header's values are joined with `", "`. The later callbacks carry
an empty map, so a handler that needs a header afterwards (an
`Authorization` token, say) keeps it keyed by `connectionId`.

### WsMessage type

```lyric
pub union WsMessage {
  case Text(text: String)
  case Binary(dataBase64: String)
  case Ping
  case Pong
  case Close(code: Int, reason: String)
}
```

### Starting a server

```lyric
Ws.startServer(host, port, path, handler) -> Result[NativeRegistry, WsError]
Ws.startServerWithConfig(host, port, path, maxMessageSizeBytes, handler)
Ws.startServerWithOptions(host, port, path, options: WsServerOptions, handler)

Ws.startServerTls(host, port, path, tls: TlsServerConfig, options: WsServerOptions, handler)

pub record WsServerOptions {
  maxMessageSizeBytes: Int = 65536        // 1024 to 67108864
  allowedOrigins: slice[String] = []
  sameHostPorts: slice[Int] = []
  maxConnections: Int = 0                 // 0 = the target's default
  idleTimeoutMs: Int = 90000              // 0 = off
  writeTimeoutMs: Int = 10000             // 0 = off
  maxOutboundBytes: Int = 1048576         // at least 1024
  handshakeTimeoutMs: Int = 10000         // 0 = off
}
```

The last five fields are described under "Limits, slow consumers and wss".

`port` must be 1 to 65535 and `path` must start with `/`.

**Origin check (cross-site WebSocket hijacking).** A browser sends `Origin`
on every WebSocket handshake and attaches the site's cookies even when a
page on another site opens the socket. The server therefore refuses a
handshake with `403 Forbidden`, before the upgrade, unless one of these
holds:
- it has no `Origin` header (non-browser clients send none);
- its `Origin` host and port equal its `Host` header (same origin; this
  is the default when `allowedOrigins` is empty);
- its `Origin` equals an entry of `allowedOrigins`, ignoring ASCII case;
- its `Origin` host equals the `Host` header's host and its port is one of
  `sameHostPorts` (a page the same application serves on a sibling port,
  such as an HTTP listener next to this WebSocket listener; a missing port
  means the scheme's default);
- `allowedOrigins` contains `"*"`, which disables the check.

The policy is `Ws.Handshake.originAllowedFor` and is the same on every
target.

**Handler failures.** If `onOpen`, `onMessage` or `onClose` throws (a
`panic`, a failed contract, a host exception), the kernel reports it to the
handler's `onError` as "the onMessage handler failed: ..." and keeps the
connection open; the next message is handled normally. An `onError` that
throws as well is written to stderr. The behaviour is the same on dotnet
and the JVM; on native a `panic` has no unwinding (D-N-003) and ends the
process.

### Sending and closing

```lyric
Ws.sendText(registry, connectionId, text) -> Result[Unit, WsError]
Ws.broadcastText(registry, text) -> Result[Unit, WsError]
Ws.closeConnection(registry, connectionId) -> Result[Unit, WsError]
Ws.connectionCount(registry) -> Int
Ws.isConnected(registry, connectionId) -> Bool
registry.close(connectionId, code: WsCloseCode, reason) -> Result[Unit, WsError]
```

A close code must be sendable (1000 to 4999, except 1004 to 1006 and
1015); any other code is `Err(INVALID_CLOSE_CODE)`. A reason longer than
123 UTF-8 bytes is cut to fit the control-frame limit. When a peer closes
without a status code, the server replies with an empty Close frame and
never puts the reserved 1005 on the wire.

## Configuration

### WsAuth aspect

Enforces JWT bearer token authentication. Validates token signature and claims
before allowing the connection to proceed.

```lyric
import Ws.Aspects

aspect GuardChat from Ws.Aspects.WsAuth {
  matches: route like "/chat/*"
  config {
    jwtSecret: String = "a-signing-key-of-at-least-32-bytes";
    issuer: String = "https://example.com";
    audience: String = "chat-api";
    algorithm: String = "HS256"
  }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `jwtSecret` | `String` | **required** | HMAC secret, at least 32 bytes |
| `issuer` | `String` | **required** | Expected JWT `iss` claim |
| `audience` | `String` | **required** | Expected JWT `aud` claim |
| `algorithm` | `String` | `"HS256"` | JWT algorithm (HS256, RS256, etc.) |

If token validation fails, the connection is rejected with a 401 Unauthorized response.

### WsRateLimit aspect

A per-connection message limit on handlers that take a `ctx: WsContext`
parameter. It is a refilling token bucket (`Resilience.TokenBucket`): up to
`messagesPerMinute + burstSize` messages at once, then `messagesPerMinute` a
minute. It works on every target (`Ws.checkRateLimit`, served by `Ws.Kernel.Net`).

```lyric
import Ws.Aspects

aspect LimitChat from Ws.Aspects.WsRateLimit {
  matches: name like "onChat*"
  config {
    messagesPerMinute: Int = 120
    burstSize: Int = 20
  }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `messagesPerMinute` | `Int` | `120` | Sustained messages allowed per minute |
| `burstSize` | `Int` | `20` | Extra messages an idle connection may send at once |

A call over the limit returns `Err(())` without running the handler; the
connection is not closed.

## Integration with lyric-web

Register the WebSocket handler with your HTTP server:

```lyric
import Web
import Ws

val wsRegistry = Ws.createRegistry()
Ws.register(wsRegistry, "/chat", chatHandler)

val router = Web.createRouter()
Web.route(router, "ws", "/ws/*", func(req: in Web.Request): Unit {
  Ws.handleUpgrade(wsRegistry, req)
})
```

See `lyric-web` documentation for full HTTP server setup.

## Decision log

See `docs/03-decision-log.md` D057; D787 (the pure-Lyric server on every target) and D792 to D795 (hardening: outbound path, limits, wss, Autobahn and permessage-deflate).
