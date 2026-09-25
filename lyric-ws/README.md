# lyric-ws

WebSocket server with pluggable backends and aspect-based security.

## Platform parity

| Feature flag | Backend                                                    | Status                                                    |
|--------------|-------------------------------------------------------------|-----------------------------------------------------------|
| `dotnet`     | Pure-Lyric RFC 6455 over `Std.TcpHost` via `Ws.Kernel.Net`  | Real: `Ws.startServer` runs a genuine `System.Net.Sockets.TcpListener`-backed server (docs/62-jsonrpc-mcp.md §6, #778). Connect, handshake (`Ws.Handshake`), send/receive (text/binary/ping/pong/close), **fragmented multi-frame message reassembly**, and **automatic ping-interval keepalive** are all real and tested end-to-end (`tests/ws_dotnet_e2e_tests.l`) — including the two capabilities the JVM kernel still lacks (see below, tracked as Q-WS-001) |
| `jvm`        | Undertow WebSocket via `Ws.Kernel.Jvm`                      | Real: `Ws.startServer` runs a genuine `io.undertow.Undertow` server; connect, send (text/binary/ping/pong/close), receive (single-frame text/binary/ping/pong), and connection-registry queries are all backed by real Undertow/XNIO calls. `scripts/ci/lyric-ws-undertow-jvm-smoke.sh` checks the Origin policy, handshake headers and a text round trip against a live server in CI (#7243; before it, the receive listener failed every event with `AbstractMethodError` and nothing noticed) |

`Ws.Kernel.Net` is pure Lyric: a minimal HTTP/1.1 upgrade-handshake
parser + `Sec-WebSocket-Accept` derivation (`Ws.Handshake`, via the new
`Std.Hash.sha1OfBytes`) and an RFC 6455 frame codec (`Ws.Frame`) on top
of the `Std.TcpHost` transport kernel — the same seam
`Std.HttpServer`/`Std.HttpEngine` use (docs/61 phase 3.3). No new NuGet
dependency; not ASP.NET Core WebSockets. Concurrency mirrors
`Std.HttpServer`'s dotnet assembly: a background `Task` runs the accept
loop, and each connection gets its own read-loop `Task` plus (when
ping keepalive is enabled) a ping-loop `Task`. See `Ws.Kernel.Net`'s
module header for the full design, including why `pingIntervalMs` is
read from `LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS` directly rather than
threaded through `startServer`'s parameters.

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
silent stubs — the dotnet kernel above does not replicate them, tracked
to close as Q-WS-001): fragmented (multi-frame) WebSocket messages are
not reassembled; automatic ping-interval keepalives are not scheduled;
text decoding is lenient UTF-8 (substitutes U+FFFD) rather than
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
| `Ws.Frame` | Pure-Lyric RFC 6455 frame codec (target-independent) |
| `Ws.Handshake` | Pure-Lyric HTTP/1.1 upgrade-handshake parser + `Sec-WebSocket-Accept` derivation (target-independent) |
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

dotnet backend is pure-Lyric RFC 6455 over `Std.TcpHost` (`Ws.Kernel.Net`, not ASP.NET Core WebSockets). JVM backend uses Undertow (`Ws.Kernel.Jvm`). See "Platform parity" above for per-target status.

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

pub record WsServerOptions {
  maxMessageSizeBytes: Int = 65536        // 1024 to 67108864
  allowedOrigins: slice[String] = []
}
```

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
- `allowedOrigins` contains `"*"`, which disables the check.

The policy is `Ws.Handshake.originAllowed` and is the same on both targets.

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
| `enabled` | `Bool` | `true` | Master switch |
| `jwtSecret` | `String` | **required** | HMAC secret, at least 32 bytes |
| `issuer` | `String` | **required** | Expected JWT `iss` claim |
| `audience` | `String` | **required** | Expected JWT `aud` claim |
| `algorithm` | `String` | `"HS256"` | JWT algorithm (HS256, RS256, etc.) |

If token validation fails, the connection is rejected with a 401 Unauthorized response.

### WsRateLimit aspect

A per-connection message limit on handlers that take a `ctx: WsContext`
parameter. It works on both targets (`Ws.checkRateLimit`).

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
| `messagesPerMinute` | `Int` | `120` | Messages allowed per one-minute window |
| `burstSize` | `Int` | `20` | Extra messages allowed once the window is used up |

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

See `docs/03-decision-log.md` D057.
