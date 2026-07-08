# lyric-ws

WebSocket server with pluggable backends and aspect-based security.

## Platform parity

| Feature flag | Backend                                     | Status                                                    |
|--------------|----------------------------------------------|-----------------------------------------------------------|
| `jvm`        | Undertow WebSocket via `Ws.Kernel.Jvm`       | Real: `Ws.startServer` runs a genuine `io.undertow.Undertow` server; connect, send (text/binary/ping/pong/close), receive (single-frame text/binary/ping/pong), and connection-registry queries are all backed by real Undertow/XNIO calls |
| `dotnet`     | ASP.NET Core WebSockets via `Ws.Kernel.Net`  | Bookkeeping only: `createRegistry`/`send`/`broadcast`/`close`/`connectionCount`/`isConnected` validate state but never touch a socket; `Ws.startServer` returns `Err(code = "SERVER_START_FAILED")` (`NOT_IMPLEMENTED`) — the real ASP.NET Core WebSocket upgrade path is deferred to #778 |

`Ws.Kernel.Jvm` binds `io.undertow:undertow-core` (declared in this
package's `[maven]` table) via `extern type` + auto-FFI — no
`extern package` (a confirmed no-op FFI mechanism) and no hand-routed
host shim. `WebSocketConnectionCallback` and the receive/close listeners
(`org.xnio.ChannelListener`) are real Lyric records implementing the
real JDK interfaces via `impl <ExternInterface> for Record` — the JVM
analog of docs/51's MSIL-only support, whose interface-name and
param/return-type resolution this library's development fixed in the
self-hosted JVM backend (`lyric-compiler/jvm/codegen/06_items.l`; see
`ffi_iface_impl_jvm_self_test.l`).

Known JVM-kernel gaps (documented in `Ws.Kernel.Jvm`'s own header, not
silent stubs): fragmented (multi-frame) WebSocket messages are not
reassembled; automatic ping-interval keepalives are not scheduled; text
decoding is lenient UTF-8 (substitutes U+FFFD) rather than
`Std.Encoding.tryDecodeUtf8`'s strict validate-and-reject, because that
pure-Lyric helper hits a separate, pre-existing self-hosted JVM backend
bug (`slice[Byte]` element indexing resolves to the JVM-erased `Object`
type instead of `Byte`, so `.toInt()` fails to compile) unrelated to
this library. A real end-to-end test
(`tests/ws_jvm_e2e_test.l` — starts a real server, connects a real
Undertow `WebSocketClient`, sends/receives a frame) is written but not
yet runnable end-to-end: it hits a further, precisely-diagnosed
self-hosted JVM backend gap in cross-package `impl` of a *native*
(non-extern) interface — see that file's header for the full
diagnosis. It is intentionally not registered in `[project.tests]`
until that gap is fixed.

## Packages

| Package | Purpose |
|---|---|
| `Ws` | Core types, `WsHandler`/`WsRegistry` interfaces, and public API |
| `Ws.Aspects` | Reusable aspect templates: `WsAuth` and `WsRateLimit` |

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

.NET backend uses ASP.NET Core WebSockets. JVM backend (Undertow) is planned for Phase 6.

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
  route: String
  remoteAddress: String
  headers: slice[Tuple[String, String]]
  attributes: slice[Tuple[String, String]]
}
```

### WsMessage type

```lyric
pub record WsMessage {
  text: String
  isText: Bool
  timestamp: Instant
}
```

### Factory and core functions

```lyric
Ws.createRegistry(): WsRegistry

Ws.register(registry: in WsRegistry, route: in String, handler: in WsHandler): Unit

Ws.receive(context: in WsContext): Option[WsMessage]

Ws.send(registry: in WsRegistry, connectionId: in String, message: in String)
  -> Result[Unit, WsError]

Ws.broadcast(registry: in WsRegistry, message: in String): Unit

Ws.close(registry: in WsRegistry, connectionId: in String): Unit

Ws.connectionCount(registry: in WsRegistry): Int
```

## Configuration

### WsAuth aspect

Enforces JWT bearer token authentication. Validates token signature and claims
before allowing the connection to proceed.

```lyric
import Ws.Aspects

aspect GuardChat from Ws.Aspects.WsAuth {
  matches: route like "/chat/*"
  config {
    jwtSecret: String = "your-secret-key";
    issuer: String = "https://example.com";
    audience: String = "chat-api";
    algorithm: String = "HS256"
  }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `jwtSecret` | `String` | `""` | HMAC secret or public key (PEM) |
| `issuer` | `String` | `""` | Expected JWT `iss` claim |
| `audience` | `String` | `""` | Expected JWT `aud` claim |
| `algorithm` | `String` | `"HS256"` | JWT algorithm (HS256, RS256, etc.) |

If token validation fails, the connection is rejected with a 401 Unauthorized response.

### WsRateLimit aspect

Token-bucket rate limiting per connection. Limits message throughput to prevent
resource exhaustion and abuse.

```lyric
import Ws.Aspects

aspect LimitChat from Ws.Aspects.WsRateLimit {
  matches: route like "/chat/*"
  config {
    messagesPerSecond: Int = 10;
    burst: Int = 20;
    windowSizeMs: Int = 1000
  }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `messagesPerSecond` | `Int` | `10` | Sustained rate limit |
| `burst` | `Int` | `20` | Burst capacity (tokens in bucket) |
| `windowSizeMs` | `Int` | `1000` | Token refill window in ms |

Requests exceeding the rate limit are rejected with a 429 Too Many Requests
response; the connection is not closed.

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

See `docs/03-decision-log.md` D057.
