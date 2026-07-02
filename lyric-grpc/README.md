# lyric-grpc

General-purpose gRPC client for [Lyric](https://github.com/nichobbs/lyric-lang). Ships low-level RPC invocation, message framing, and protocol handling for calling gRPC services from Lyric applications.

> **Status**: @experimental — the API compiles and proto-encoding has unit-level tests, but the end-to-end client + server pair has not been exercised against a real gRPC service in CI. `.NET` and JVM backends are available via feature flags.

## Platform parity

| Feature flag | Backend | Status |
|---|---|---|
| `dotnet` | `Grpc.Net.Client` via `Grpc.Kernel.Net` | Available |
| `jvm` | `io.grpc:grpc-netty-shaded` via `Grpc.Kernel.Jvm` | Phase 6 (planned) |

## Packages

| Package | Description |
|---|---|
| `Grpc` | Core: RPC calls, channel management, metadata |
| `Grpc.Kernel.Net` | .NET extern boundary (ASP.NET Core gRPC) |
| `Grpc.Kernel.Jvm` | JVM extern boundary (grpc-java) |

## Installation

```toml
[dependencies]
"Lyric.Grpc" = { path = "../lyric-grpc" }

[features]
dotnet = []    # enable .NET backend
jvm = []       # enable JVM backend
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

## Package layout

```
lyric-grpc/
  lyric.toml                  package manifest
  README.md                   this file
  src/
    grpc.l                    Grpc  (channels, RPC invocation)
    types.l                   Grpc.Types  (types, metadata)
    aspects.l                 Grpc.Aspects  (planned aspect templates)
    _kernel/
      net/
        grpc_kernel.l         Grpc.Kernel.Net  (.NET extern boundary)
      jvm/
        grpc_kernel.l         Grpc.Kernel.Jvm  (JVM extern boundary)
  tests/
    *_tests.l                 test modules
```

## See also

- `lyric-proto` — Protocol Buffer encoding/decoding (for payloads)
- [gRPC documentation](https://grpc.io) (external reference)
- `docs/37-grpc-proto-sketch.md` — exploratory design sketch for gRPC and Protobuf; unbacked (Q-G-001–Q-G-007 open)
- `docs/03-decision-log.md` D068 — design decisions for this library
