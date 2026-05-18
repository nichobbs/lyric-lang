// Grpc.Kernel.Net — .NET extern boundary for gRPC client and server.
//
// Client side (Grpc.Net.Client):
//   netOpenChannel / netCloseChannel — channel lifecycle
//   netCallUnary                     — blocking unary RPC
//   netOpenServerStream / netNextStreamMessage / netCloseStream — server streaming
//
// Server side (Grpc.AspNetCore):
//   serve()          — start the gRPC server host
//   checkRateLimit() — in-process sliding-window rate limiter
//
// Pass-through marshaller: the client uses a Grpc.Core.Marshaller<byte[]>
// whose serialiser and deserialiser are identity functions, so Lyric callers
// supply and receive raw protobuf bytes without generated stub code.
//
// For each incoming server RPC the kernel:
//   1. Matches the request against the GrpcRoute table.
//   2. Deserializes the protobuf request message to the handler's first param.
//   3. Extracts "authorization" metadata and passes it as `authToken: String`.
//   4. Resolves the handler by qualified name and invokes it.
//   5. Maps Result[T, GrpcStatus] → gRPC response:
//        Ok(value)   → Status.OK + serialized response
//        Err(status) → status.code + status.message in trailing metadata
//
// JWT verification lives in Auth.Kernel.Net (lyric-auth).
//
// Only active when compiled with feature = "dotnet".
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Grpc.Kernel.Net

import Grpc.Types

// ─── Opaque .NET types ────────────────────────────────────────────────────────

extern type NetGrpcChannel = "Grpc.Net.Client.GrpcChannel"
extern type NetGrpcStream  = "System.Collections.Generic.IAsyncEnumerator`1[System.Byte[]]"

// ─── Client: channel lifecycle ────────────────────────────────────────────────

@axiom("Grpc.Net.Client.GrpcChannel conforms to its NuGet contract")
extern package Grpc.Net.Client.Api {
  pub func netOpenChannel(address: in String): Result[GrpcChannel, String]
  pub func netCloseChannel(channel: GrpcChannel): Unit
}

// ─── Client: unary calls ──────────────────────────────────────────────────────

@axiom("Grpc.Net.Client CallInvoker with pass-through marshaller conforms to its NuGet contract")
extern package Grpc.Net.Client.Unary {
  pub func netCallUnary(
    channel:   GrpcChannel,
    service:   in String,
    method:    in String,
    payload:   in [Byte],
    timeoutMs: in Int,
    metadata:  in String
  ): Result[[Byte], GrpcStatus]
}

// ─── Client: server-streaming calls ──────────────────────────────────────────

@axiom("Grpc.Net.Client server-streaming CallInvoker conforms to its NuGet contract")
extern package Grpc.Net.Client.Stream {
  pub func netOpenServerStream(
    channel:   GrpcChannel,
    service:   in String,
    method:    in String,
    payload:   in [Byte],
    timeoutMs: in Int,
    metadata:  in String
  ): Result[GrpcStream, GrpcStatus]

  pub func netNextStreamMessage(stream: GrpcStream): Result[Option[[Byte]], GrpcStatus]
  pub func netCloseStream(stream: GrpcStream): Unit
}

// ─── Server: hosting ─────────────────────────────────────────────────────────

@axiom("Grpc.AspNetCore / grpc-dotnet server host")
extern package Grpc.AspNetCore {
  pub func serve(
    host:               String,
    port:               Int,
    reflectionEnabled:  Bool,
    maxConnectionIdleMs: Int,
    registry:           Grpc.ServiceRegistry
  ): Unit
}

@axiom("Grpc.AspNetCore IHost.StopAsync provides drain-with-timeout shutdown")
extern package Grpc.AspNetCore.Managed {
  pub func netStartHandle(
    host:               String,
    port:               Int,
    reflectionEnabled:  Bool,
    maxConnectionIdleMs: Int,
    registry:           Grpc.ServiceRegistry
  ): GrpcServerHandle

  pub func netStopHandle(handle: GrpcServerHandle, drainTimeoutMs: Int): Unit
    requires: drainTimeoutMs >= 0
}

// ─── Server: rate limiting ────────────────────────────────────────────────────

@axiom("In-process sliding-window rate limiter (System.Threading.RateLimiting)")
extern package System.Threading.RateLimiting {
  pub func checkRateLimit(
    method:            String,
    requestsPerMinute: Int,
    burstSize:         Int
  ): Bool
    requires: requestsPerMinute > 0
    requires: burstSize > 0
}
