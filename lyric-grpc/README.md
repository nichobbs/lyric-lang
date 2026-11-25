# lyric-grpc

**Stability:** `experimental`

General-purpose gRPC client for [Lyric](https://github.com/nichobbs/lyric-lang). Ships low-level RPC invocation, message framing, and protocol handling for calling gRPC services from Lyric applications.

> **Status**: @experimental. The **client** is pure Lyric (`Grpc.Client` over `Std.HttpEngine.H2Client`, docs/72 slice 6, D802) on both targets, pooled and multiplexed, with gzip, `openChannelWith` (TLS trust and identity, limits, keepalive, idle timeout, reconnect backoff) and one transparent retry of unprocessed streams; the `legacy-client` feature selects the former SDK kernels until slice 10. It is covered by end-to-end tests against in-process gRPC servers: `openChannel`/`closeChannel`, `callUnary`, `openServerStream`/`nextMessage`/`closeStream`, call metadata, deadlines, status mapping, and `checkRateLimit`. **Server hosting** (`addUnary`, `addServerStreaming`, `start`, `startTls`, `startHandle`, `startHandleAt`, `startHandleTlsAt`, `stop`) is pure Lyric on both targets (`Grpc.Server` over `Std.HttpEngine.H2Conn`, docs/72 slice 8, D804): unary and server-streaming methods over h2c and TLS, gzip request decode, `grpc-timeout` enforcement and handler panic isolation, covered by `tests/server_tests.l`, `tests/server_h2_tests.l` and, against independent clients, `tests/server_interop_dotnet_tests.l` (`Grpc.Net.Client`) and `tests/server_interop_jvm_tests.l` (grpc-java). The aspect templates in `Grpc.Aspects` are `dotnet` only.

## Platform parity

The client below is `Grpc.Client` unless built with `--features legacy-client`. Its tests are target neutral: `tests/client_h2_tests.l` (a scripted `H2Conn` peer: Trailers-Only, non-200, bad content type, status tables, large messages, `MAX_CONCURRENT_STREAMS`, GOAWAY, retry, idle close, TLS) and `tests/wire_tests.l`; `tests/client_dotnet_tests.l` runs it against a pure-Lyric peer on dotnet, `tests/client_jvm_tests.l` against a grpc-java server on the JVM, and `tests/server_tests.l` against the pure-Lyric server on both.

Behaviour to know: one HTTP/2 connection per channel by default (`ChannelOptions.maxConnections`), calls beyond the server's `MAX_CONCURRENT_STREAMS` queue first-in first-out; a failed dial makes calls fail `Unavailable` until a jittered backoff elapses; a call refused or above a GOAWAY's last-stream-id is sent once more, nothing else is retried; responses over `maxReceiveMessageBytes` (4 MiB, also decompressed) are `ResourceExhausted`; `grpc-status-details-bin` is not parsed; error text differs from Grpc.Net and grpc-java, so do not match on it. **Native (D803):** the client builds and passes `grpc_types_tests.l`, `wire_tests.l` and `client_h2_tests.l` on `--target native` (`lyric test --manifest lyric-grpc/lyric.toml --target native --no-default-features --features native`); the server (`start`, `startHandle`, `stop`, `serverPort`), `checkRateLimit` and the aspect templates are not built there until the portable server of docs/72 slice 8.

| Feature flag | Backend | Client | Server hosting | Tests |
|---|---|---|---|---|
| `dotnet` | `Grpc.Net.Client` / `Grpc.Core.Api` via `Grpc.Kernel.Net` | unary, server streaming, metadata, deadlines, `checkRateLimit` | unary, server streaming (`Grpc.Server`, h2c and TLS) | `tests/server_tests.l`, `tests/server_h2_tests.l`, `tests/server_interop_dotnet_tests.l`, `tests/client_dotnet_tests.l` (pure-Lyric h2c test peer on `Std.HttpEngine.H2Conn`), `tests/rate_limit_tests.l`, `tests/channel_lifecycle_tests.l` |
| `jvm` | `io.grpc:grpc-netty-shaded` / `grpc-stub` via `Grpc.Kernel.Jvm` | unary, server streaming, metadata, deadlines, `checkRateLimit` | unary, server streaming (`Grpc.Server`, h2c and TLS) | `tests/server_tests.l`, `tests/server_h2_tests.l`, `tests/server_interop_jvm_tests.l` (grpc-java client), `tests/client_jvm_tests.l` (grpc-java `Server` test peer), `tests/rate_limit_jvm_tests.l` |

Differences to know about:

- **Addresses.** `.NET` accepts any absolute `http(s)` URI `GrpcChannel.ForAddress` accepts. The JVM accepts `http://host[:port]` (plaintext) or `https://host[:port]` (TLS) with no path, query or whitespace (`Grpc.Types.parseAddress`), because a grpc-java target carries none.
- **Rate limiting.** `.NET` composes a 60 s sliding window at `requestsPerMinute` with a 1 s window at `burstSize`. The JVM uses the `Lyric.Resilience` token bucket: `requestsPerMinute + burstSize` permits, refilled at `requestsPerMinute` a minute. Both return `false` when the method's budget is spent; the margins differ.
- **Errors.** A failed call is `Err(GrpcStatus)` with the server's code and message (`Grpc.Types.statusFromException` reads grpc-dotnet's `Status(StatusCode="...", Detail="...")` and grpc-java's `CODE: description`). A closed channel is `FailedPrecondition`; no server is `Unavailable`; an expired `withTimeout` is `DeadlineExceeded`. Server-streaming failures arrive from `nextMessage`, not from `openServerStream`, because a call that has not started reading has not failed yet.
- **Handles.** A `GrpcStream` that is dropped without `closeStream` keeps its call alive until the call's deadline or the server ends it: always close streams, as with channels.
- **Payloads** are raw `slice[Byte]` (protobuf bytes) on both targets: compose with `lyric-proto`.

## Packages

| Package | Description |
|---|---|
| `Grpc` | Core: RPC calls, channel management, metadata |
| `Grpc.Client` | Pure-Lyric client over `Std.HttpEngine.H2Client` (default) |
| `Grpc.Wire` | gRPC-over-HTTP/2 framing, gzip, `grpc-timeout`, status mapping |
| `Grpc.Kernel.Net` | .NET extern boundary (ASP.NET Core gRPC) |
| `Grpc.Kernel.Jvm` | JVM extern boundary (grpc-java) |

## Installation

```toml
[dependencies]
"Lyric.Grpc" = { path = "../lyric-grpc" }

[features]
dotnet = []    # rate limit and SDK dependencies (.NET)
jvm = []       # the same for the JVM
legacy-client = []  # use the SDK client kernels instead of Grpc.Client (removed in slice 10)
```

## Quick start

### Unary RPC call

```lyric
import Grpc
import Proto

// Create a channel to the service
match Grpc.openChannel("https://grpc.example.com:50051") {
  case Ok(channel) -> {
    // Prepare the request payload (use lyric-proto for encoding)
    val requestBytes = Proto.encodeMessage([
      Proto.VarField(1, 42i64)
    ])

    // Call the RPC
    match Grpc.callUnary(
      channel,
      service = "pkg.MyService",
      method = "MyMethod",
      payload = requestBytes,
      opts = Grpc.defaultOptions()
    ) {
      case Ok(responseBytes) -> {
        // Decode the response bytes with lyric-proto
        val decoded = ... // decode response bytes
      }
      case Err(status) -> {
        // RPC failed; check status.code
      }
    }

    Grpc.closeChannel(channel)
  }
  case Err(e) -> {
    // Channel creation failed
  }
}
```

### Server-streaming RPC call

```lyric
import Grpc
import Proto

match Grpc.openChannel("https://grpc.example.com:50051") {
  case Ok(channel) -> {
    val requestBytes = Proto.encodeMessage([
      Proto.VarField(1, 42i64)
    ])

    // Start server-streaming RPC
    match Grpc.openServerStream(
      channel,
      service = "pkg.MyService",
      method = "MyStream",
      payload = requestBytes,
      opts = Grpc.defaultOptions()
    ) {
      case Ok(stream) -> {
        // Read messages from the stream
        var done = false
        while !done {
          match Grpc.nextMessage(stream) {
            case Ok(Some(message)) -> {
              // Process message (protobuf-encoded bytes)
              val decoded = ... // decode with Proto
            }
            case Ok(None) -> {
              // Stream complete
              done = true
            }
            case Err(status) -> {
              // Stream error
              done = true
            }
          }
        }
        Grpc.closeStream(stream)
      }
      case Err(status) -> {
        // RPC failed
      }
    }

    Grpc.closeChannel(channel)
  }
  case Err(e) -> {}
}
```

## Channel management

### Create a channel

```lyric
import Grpc

// HTTP/2 channel (encrypted with HTTPS URL, unencrypted with HTTP URL)
match Grpc.openChannel("https://grpc.example.com:50051") {
  case Ok(channel) -> {
    // Use channel for RPC calls
  }
  case Err(e) -> {
    // Connection failed
  }
}
```

### Close a channel

```lyric
Grpc.closeChannel(channel)
```

Channels pool connections; closing a channel closes all pooled connections.

### Metadata (headers)

Pass custom metadata (gRPC headers) with requests using `withMetadata` on options:

```lyric
import Grpc
import Std.Core

var opts = Grpc.defaultOptions()
opts = Grpc.withMetadata(opts, "authorization", "Bearer token123")
opts = Grpc.withMetadata(opts, "x-request-id", "abc-def-ghi")

match Grpc.callUnary(
  channel,
  service = "MyService",
  method = "MyMethod",
  payload = requestBytes,
  opts = opts
) {
  case Ok(response) -> { /* handle response */ }
  case Err(status)  -> { /* handle error */ }
}
```

## RPC types

### Unary

Single request → single response.

```lyric
pub func callUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions
): Result[slice[Byte], GrpcStatus]
```

Returns the protobuf-encoded response payload on success.

### Server streaming

Single request → stream of responses.

```lyric
pub func openServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions
): Result[GrpcStream, GrpcStatus]

pub func nextMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus]
pub func closeStream(stream: in GrpcStream): Unit
```

Call `nextMessage` repeatedly; it returns `Ok(Some(bytes))` for each message, `Ok(None)` when the stream closes cleanly, or `Err(status)` on error.

## Low-level API

### Channel operations

#### `openChannel`

Open an HTTP/2 channel to a gRPC service.

```lyric
pub func openChannel(address: in String): Result[GrpcChannel, String]
```

| Parameter | Description |
|---|---|
| `address` | Full URL: `"https://host:port"` or `"http://host:port"` |

Returns `Ok(channel)` on success; `Err(message)` if the address is malformed or connection fails.

#### `closeChannel`

Close a channel and release all pooled HTTP/2 connections.

```lyric
pub func closeChannel(channel: in GrpcChannel): Unit
```

### RPC invocation

#### `callUnary`

Make a unary (single request/response) gRPC call.

```lyric
pub func callUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions
): Result[slice[Byte], GrpcStatus]
```

| Parameter | Description |
|---|---|
| `service` | Fully-qualified proto service name: `"pkg.ServiceName"` |
| `method` | Unqualified RPC method name: `"GetItem"` |
| `payload` | Protobuf-encoded request body (use `lyric-proto`) |
| `opts` | Call options (timeout, metadata); use `defaultOptions()` for defaults |

Returns the protobuf-encoded response on success; `Err(status)` on failure with detailed error code.

#### `openServerStream`

Start a server-streaming gRPC call.

```lyric
pub func openServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  payload: in slice[Byte],
  opts: in GrpcCallOptions
): Result[GrpcStream, GrpcStatus]
```

### Stream operations

#### `nextMessage`

Read the next message from a server-streaming response.

```lyric
pub func nextMessage(stream: in GrpcStream): Result[Option[slice[Byte]], GrpcStatus]
```

Returns:
- `Ok(Some(bytes))` — next message (protobuf-encoded)
- `Ok(None)` — stream ended cleanly
- `Err(status)` — stream error (check `status.code`)

#### `closeStream`

Close a stream and release resources. Always call this when done, even if `nextMessage` returned `None`.

```lyric
pub func closeStream(stream: in GrpcStream): Unit
```

### Call options

#### `defaultOptions`

Create call options with no deadline or metadata.

```lyric
pub func defaultOptions(): GrpcCallOptions
```

#### `withTimeout`

Set a deadline (milliseconds from now).

```lyric
pub func withTimeout(opts: in GrpcCallOptions, ms: in Int): GrpcCallOptions
```

#### `withMetadata`

Add a metadata header entry.

```lyric
pub func withMetadata(opts: in GrpcCallOptions, metaKey: in String, metaValue: in String): GrpcCallOptions
```

## Usage with lyric-proto

Combine with `lyric-proto` for message encoding/decoding:

```lyric
import Grpc
import Proto
import Std.Core

// Encode request using Proto field helpers
val requestFields = [
  Proto.VarField(1, userId.toLong()),
]
val requestBytes = Proto.encodeMessage(requestFields)

// Invoke RPC
match Grpc.callUnary(
  channel,
  service = "UserService",
  method = "GetUser",
  payload = requestBytes,
  opts = Grpc.defaultOptions()
) {
  case Ok(responseBytes) -> {
    // Decode response
    match Proto.decodeMessage(responseBytes) {
      case Ok(fields) -> {
        // parse response fields
      }
      case Err(e) -> {
        // decode error
      }
    }
  }
  case Err(status) -> {
    // RPC error
  }
}
```

## Error handling

All RPC calls return `Result[T, GrpcStatus]`. Common errors:

| Error | Meaning |
|---|---|
| `Unavailable` | Service not reachable |
| `DeadlineExceeded` | Request timeout |
| `InvalidArgument` | Bad request payload |
| `NotFound` | RPC method not found |
| `Internal` | Server error |
| `Unauthenticated` | Missing or invalid credentials |
| `PermissionDenied` | Caller lacks permission |

## Server API

Build a `ServiceRegistry` of handlers per `(service, method)`, then start the
server. Handlers are Lyric values (functions or lambdas), not names.

```lyric
import Grpc
import Grpc.Types
import Std.Core

func echo(req: in slice[Byte], meta: in slice[GrpcMetadataEntry]): Result[slice[Byte], GrpcStatus] {
  Ok(req)
}

func countTo(
  req: in slice[Byte],
  meta: in slice[GrpcMetadataEntry],
  emit: in (slice[Byte]) -> Bool,
): Result[Unit, GrpcStatus] {
  var i = 0
  while i < req[0].toInt() {
    if not emit([i.toByte()]) {
      return Ok(())   // the client went away: stop producing
    }
    i = i + 1
  }
  Ok(())
}

var registry = Grpc.create()
registry = Grpc.addUnary(registry, "pkg.MyService", "Echo", echo)
registry = Grpc.addServerStreaming(registry, "pkg.MyService", "Count", countTo)

// Blocking start: serves until the process exits.
Grpc.start(registry)
```

A handler receives the request message (raw protobuf bytes) and the request
metadata (lowercase keys; pseudo-headers, `content-type`, `te`, `user-agent`,
`grpc-*` and `-bin` keys are left out). It returns the response or the status to
fail the call with. A handler that panics fails its call with `Internal` and no
detail, and never takes the server down.

### Configuration

The server reads its host/port/reflection settings from the `GrpcServer`
config block (wire it up via the usual `config { }` mechanism):

```lyric
config GrpcServer {
  host: String = "0.0.0.0"
  port: Int range 1 ..= 65535 = 50051
  reflectionEnabled: Bool = false
  maxConnectionIdleMs: Int range 1 ..= 2147483647 = 300000
}
```

`reflectionEnabled = true` panics at start: server reflection is not supported.
`maxConnectionIdleMs` closes a connection with no calls in flight that stays
silent that long. `start`, `startHandle` and `startHandleAt` serve plaintext
HTTP/2 (`http://` clients); `startTls` and `startHandleTlsAt` serve TLS.

### Non-blocking start and graceful shutdown

```lyric
import Grpc

val handle = Grpc.startHandle(registry)
// ... application continues running ...
// Stop accepting calls, wait up to 5 s for the ones in flight, then close.
Grpc.stop(handle, 5000)
```

`Grpc.startHandleAt(registry, "127.0.0.1", 0)` binds an explicit address (port
`0` = ephemeral) and `Grpc.serverPort(handle)` reports the port, which is what
the tests use. Binding a taken port panics rather than returning a dead handle.

### TLS

```lyric
import Std.Tls

val identity = Identity.fromPem(certChainPem, keyPem).unwrap()
val handle = Grpc.startHandleTlsAt(registry, "0.0.0.0", 50051, TlsServerConfig(identity = identity))
```

The same `Std.Tls.TlsServerConfig` as `Std.HttpServer`: a certificate chain and a
PKCS8 key, a minimum protocol version (TLS 1.2 by default) and optional mutual TLS
(`requireClientCert` with a `clientCa`; `requireClientCert` without one panics when
the server starts, not on every handshake). The server negotiates ALPN `h2`, runs
each handshake on the connection's own task (10 s limit) and closes a client that
negotiated anything else. A client reaches it at `https://host:port`.

### Server API reference

| Function | Description |
|---|---|
| `create(): ServiceRegistry` | An empty registry |
| `addUnary(registry, service, method, handler)` | Register a unary method; registering the same `(service, method)` twice violates its contract |
| `addServerStreaming(registry, service, method, handler)` | Register a server-streaming method; `emit` returns `false` once the client has gone |
| `start(registry): Unit` | Serve on the `GrpcServer` config address, blocking until the process exits |
| `startHandle(registry): GrpcServerHandle` | `start` without blocking |
| `startHandleAt(registry, host, port): GrpcServerHandle` | `startHandle` on an explicit address |
| `startTls(registry, tls): Unit`, `startHandleTlsAt(registry, host, port, tls): GrpcServerHandle` | The same over TLS (`Std.Tls.TlsServerConfig`) |
| `requestTimeoutMs(meta): Option[Long]` | The time the caller's deadline left when the handler was dispatched |
| `serverPort(handle): Int` | The bound port (`0` once stopped) |
| `stop(handle, drainTimeoutMs): Unit` | Stop accepting, drain, then close; a second stop is a no-op |

### Server limits and differences

The server is one pure-Lyric implementation for dotnet and the JVM (`Grpc.Server`:
`Std.HttpEngine.H2Conn` over `Std.TcpHost`, tasks and locks from `Std.HttpServerHost`).
It began as the dotnet-only h2c server of D287; D804 made it portable, deleted the
grpc-java `Server` the JVM used, and lifted three of D287's limits.

- **Messages.** Unary and server-streaming only (no client or bidirectional
  streaming: slice 9). One request message of at most 4 MiB, measured after
  decompression.
- **Compression (lifted).** `grpc-encoding: gzip` and `identity` requests are
  decoded, the gzip body expanded under the 4 MiB bound (a decompression bomb is
  `ResourceExhausted` before it is built; a body that is not gzip is `Internal`).
  Any other encoding is `Unimplemented` with `grpc-accept-encoding: identity,gzip`.
  **Kept:** responses are never compressed.
- **Deadlines (lifted).** A `grpc-timeout` is enforced: when it passes before the
  handler answers, the call ends with `DeadlineExceeded`, the handler's later
  result is dropped and a streaming handler's `emit` returns `false`. A unary
  handler cannot be interrupted, so it runs to completion in the background; check
  `Grpc.requestTimeoutMs(meta)` in long handlers and stop early. A malformed
  `grpc-timeout` is `Internal`. Each call with a deadline costs one extra task for
  its lifetime.
- **TLS (lifted).** See above.
- **Concurrency.** One task reads each connection and every call's handler runs on
  its own task; a call that does not fit the peer's flow-control window waits up to
  30 s for it to open. Kept from D287: no server reflection, no per-call response
  compression, HTTP/2 only (no gRPC-web).
- **Panics.** A panicking handler, unary or streaming, ends its call with `Internal`
  and no detail (tested on both targets); the connection and server carry on.
- **Aspects** (`Grpc.Aspects`) are dotnet only.

### Server types

| Type | Description |
|---|---|
| `ServiceRegistry` | Immutable registry of `GrpcRoute`s |
| `GrpcRoute` | One registered method: service, method, and its `GrpcHandler` |
| `GrpcHandler` | `Unary(handle)` or `ServerStreaming(handle)` |
| `GrpcServerHandle` | Opaque handle to a running server, created by `startHandle`, passed to `stop` |

## Package layout

```
lyric-grpc/
  lyric.toml                  package manifest
  README.md                   this file
  src/
    grpc.l                    Grpc  (channels, RPC invocation)
    types.l                   Grpc.Types  (types, metadata)
    aspects.l                 Grpc.Aspects  (auth, role and circuit-breaker aspect templates)
    client.l                  Grpc.Client  (pure-Lyric client over Std.HttpEngine.H2Client)
    server.l                  Grpc.Server  (pure-Lyric server over Std.HttpEngine.H2Conn, h2c and TLS)
    wire.l                    Grpc.Wire  (framing, gzip, timeouts, status tables)
    _kernel/
      net/
        grpc_kernel.l         Grpc.Kernel.Net  (.NET extern boundary: legacy client, rate limiter)
      jvm/
        grpc_kernel.l         Grpc.Kernel.Jvm  (JVM extern boundary: legacy client, rate limiter)
  tests/
    *_tests.l                 test modules
```

## Authentication aspects

`Grpc.Aspects.RequiresGrpcAuth` and `RequiresGrpcRole` verify a bearer JWT
from the handler's `authToken: String` parameter with `Auth.verifyJwt`.
Every instantiation must supply:

- `jwtSecret`: at least 32 bytes of UTF-8 (`Auth.minHmacSecretBytes()`);
- `issuer` and `audience`: the values the token's `iss` and `aud` claims
  must carry.

```lyric
aspect GrpcAuth from Grpc.Aspects.RequiresGrpcAuth {
  matches: visibility: pub
  config {
    @sensitive
    jwtSecret: String = "REPLACE_ME_WITH_A_REAL_SECRET"
    issuer: String = "my-service"
    audience: String = "my-service-api"
  }
}
```

A missing or empty token is answered with 16 UNAUTHENTICATED and an invalid
one with 7 PERMISSION_DENIED; neither reaches the handler.  A secret that is
too short, or an algorithm list that is empty or names `none`, is a
configuration bug: the aspect panics before handling the request, with a
message naming the problem (`Auth.jwtConfigProblem`).

**Migration.** `issuer` and `audience` used to default to `""`, which
skipped the `iss`/`aud` checks, so a token minted for any other service
sharing the secret was accepted.  They no longer have defaults: an
instantiation that omits them fails to build (A0044).  Add the two fields,
and lengthen the secret if it is under 32 bytes.

## See also

- `lyric-proto` — Protocol Buffer encoding/decoding (for payloads)
- [gRPC documentation](https://grpc.io) (external reference)
- `docs/37-grpc-proto-sketch.md` — exploratory design sketch for gRPC and Protobuf; unbacked (Q-G-001–Q-G-007 open)
- `docs/03-decision-log.md` D068 — design decisions for this library
