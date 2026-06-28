# lyric-grpc

General-purpose gRPC client for [Lyric](https://github.com/nichobbs/lyric-lang). Ships low-level RPC invocation, message framing, and protocol handling for calling gRPC services from Lyric applications.

> **Status**: Library source is complete. `.NET` and JVM backends are available via feature flags.

## Platform parity

| Feature flag | Backend | Status |
|---|---|---|
| `dotnet` | `Grpc.Net.Client` via `GrpcClient.Kernel.Net` | Available |
| `jvm` | `io.grpc:grpc-netty-shaded` via `GrpcClient.Kernel.Jvm` | Available |

## Packages

| Package | Description |
|---|---|
| `GrpcClient` | Core: RPC calls, channel management, metadata |
| `GrpcClient.Kernel.Net` | .NET extern boundary (ASP.NET Core gRPC) |
| `GrpcClient.Kernel.Jvm` | JVM extern boundary (grpc-java) |

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
import GrpcClient
import Std.Core

// Create a channel to the service
val channel = GrpcClient.createChannel("grpc.example.com:50051")

// Prepare the request payload (use lyric-proto for encoding)
val requestBytes = ... // slice[Byte] encoded with proto

// Call the RPC
match GrpcClient.invokeUnary(
  channel,
  service = "MyService",
  method = "MyMethod",
  requestData = requestBytes
) {
  case Ok(response) -> {
    // Decode the response bytes with lyric-proto
    val decoded = ... // decode response bytes
  }
  case Err(e) -> {
    // RPC failed
  }
}
```

### Streaming RPC call

```lyric
import GrpcClient
import Std.Core

// Server-streaming RPC
match GrpcClient.invokeServerStream(
  channel,
  service = "MyService",
  method = "MyMethod",
  requestData = requestBytes
) {
  case Ok(stream) -> {
    // Read messages from the stream
    match GrpcClient.streamRead(stream) {
      case Some(message) -> {
        // Process message
      }
      case None -> {
        // Stream complete
      }
    }
  }
  case Err(e) -> {
    // RPC failed
  }
}
```

## Channel management

### Create a channel

```lyric
import GrpcClient

// HTTP/2 channel to an unencrypted endpoint
val channel = GrpcClient.createChannel("localhost:50051")

// HTTPS (TLS) channel with system certificate store
val secureChannel = GrpcClient.createSecureChannel("grpc.example.com:443")
```

### Close a channel

```lyric
GrpcClient.closeChannel(channel)
```

Channels pool connections; closing a channel closes all pooled connections.

### Metadata (headers)

Pass custom metadata (gRPC headers) with requests:

```lyric
import GrpcClient
import Std.Core

val metadata = [
  GrpcClient.metadataEntry("authorization", "Bearer token123"),
  GrpcClient.metadataEntry("x-request-id", "abc-def-ghi"),
]

match GrpcClient.invokeUnaryWithMetadata(
  channel,
  service = "MyService",
  method = "MyMethod",
  requestData = requestBytes,
  metadata = metadata
) {
  case Ok(response) -> { /* handle response */ }
  case Err(e)       -> { /* handle error */ }
}
```

## RPC types

### Unary

Single request → single response.

```lyric
pub func invokeUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  requestData: in slice[Byte]
): Result[slice[Byte], GrpcError]
```

### Server streaming

Single request → stream of responses.

```lyric
pub func invokeServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  requestData: in slice[Byte]
): Result[GrpcStream, GrpcError]

pub func streamRead(stream: in GrpcStream): Option[slice[Byte]]
pub func streamClose(stream: in GrpcStream): Unit
```

### Client streaming

Stream of requests → single response. (Planned Phase 6 JVM; currently `.NET` only.)

```lyric
pub func invokeClientStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String
): Result[GrpcStream, GrpcError]

pub func streamWrite(stream: in GrpcStream, data: in slice[Byte]): Result[Unit, GrpcError]
pub func streamClose(stream: in GrpcStream): Unit
```

### Bidirectional streaming

Stream of requests ↔ stream of responses. (Planned Phase 6 JVM; currently `.NET` only.)

```lyric
pub func invokeBidiStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String
): Result[GrpcStream, GrpcError]

pub func streamRead(stream: in GrpcStream): Option[slice[Byte]]
pub func streamWrite(stream: in GrpcStream, data: in slice[Byte]): Result[Unit, GrpcError]
pub func streamClose(stream: in GrpcStream): Unit
```

## Low-level API

### Channel operations

#### `createChannel`

Create an unencrypted HTTP/2 channel.

```lyric
pub func createChannel(target: in String): GrpcChannel
```

| Parameter | Description |
|---|---|
| `target` | Host and port: `"host:port"` |

#### `createSecureChannel`

Create an HTTPS/TLS-encrypted channel with system certificates.

```lyric
pub func createSecureChannel(target: in String): GrpcChannel
```

#### `closeChannel`

Close a channel and all pooled connections.

```lyric
pub func closeChannel(channel: in GrpcChannel): Unit
```

### RPC invocation

#### `invokeUnary`

Make a unary RPC call.

```lyric
pub func invokeUnary(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  requestData: in slice[Byte]
): Result[slice[Byte], GrpcError]
```

#### `invokeUnaryWithMetadata`

Unary RPC with custom headers.

```lyric
pub func invokeUnaryWithMetadata(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  requestData: in slice[Byte],
  metadata: in [GrpcMetadataEntry]
): Result[slice[Byte], GrpcError]
```

#### `invokeServerStream`

Server-streaming RPC.

```lyric
pub func invokeServerStream(
  channel: in GrpcChannel,
  service: in String,
  method: in String,
  requestData: in slice[Byte]
): Result[GrpcStream, GrpcError]
```

### Stream operations

#### `streamRead`

Read the next message from a stream.

```lyric
pub func streamRead(stream: in GrpcStream): Option[slice[Byte]]
```

Returns `None` when the stream is closed.

#### `streamWrite`

Write a message to a stream (client or bidirectional only).

```lyric
pub func streamWrite(
  stream: in GrpcStream,
  data: in slice[Byte]
): Result[Unit, GrpcError]
```

#### `streamClose`

Close a stream and release resources.

```lyric
pub func streamClose(stream: in GrpcStream): Unit
```

### Metadata

#### `metadataEntry`

Create a metadata header entry.

```lyric
pub func metadataEntry(key: in String, value: in String): GrpcMetadataEntry
```

## Usage with lyric-proto

Combine with `lyric-proto` for automatic message encoding/decoding:

```lyric
import GrpcClient
import Proto
import Std.Core

// Encode request
val reqBuf = Proto.createBuffer()
reqBuf = Proto.encodeVarint(reqBuf, 1, 0, userId)
val requestBytes = Proto.bufferBytes(reqBuf)

// Invoke RPC
match GrpcClient.invokeUnary(channel, "UserService", "GetUser", requestBytes) {
  case Ok(responseBytes) -> {
    // Decode response
    val decoder = Proto.createDecoder(responseBytes)
    // parse response fields
  }
  case Err(e) -> {
    // handle error
  }
}
```

## Error handling

All RPC calls return `Result[T, GrpcError]`. Common errors:

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
    grpc.l                    GrpcClient  (channels, RPC invocation)
    types.l                   GrpcClient  (types, metadata)
    aspects.l                 GrpcClient.Aspects  (planned aspect templates)
    _kernel/
      net/
        grpc_kernel.l         GrpcClient.Kernel.Net  (.NET extern boundary)
      jvm/
        grpc_kernel.l         GrpcClient.Kernel.Jvm  (JVM extern boundary)
  tests/
    *_tests.l                 test modules
```

## See also

- `lyric-proto` — Protocol Buffer encoding/decoding (for payloads)
- [gRPC documentation](https://grpc.io) (external reference)
- `docs/37-grpc-proto-sketch.md` — design decisions for gRPC and Protobuf
- `docs/03-decision-log.md` D068 — design decisions for this library
