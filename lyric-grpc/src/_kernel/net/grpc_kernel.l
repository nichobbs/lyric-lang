/// .NET kernel boundary for lyric-grpc.
///
/// Wraps Grpc.Net.Client (GrpcChannel, CallInvoker) using a pass-through byte[]
/// marshaller so that the Lyric caller supplies and receives raw protobuf bytes
/// without any generated stub code.
///
/// Pass-through marshaller: a Grpc.Core.Marshaller<byte[]> whose serialiser is
/// the identity function and whose deserialiser is likewise identity.  This is
/// the standard Grpc.Net.Client pattern for untyped / reflection-based calls.
///
/// The GrpcChannel object is held as an opaque Lyric type; the F# emitter
/// generates the IL to hold it in a .NET object field.  closeChannel disposes
/// the channel and releases HTTP/2 connections.
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package Grpc.Kernel.Net

import Grpc.Types
import Std.Core

// ─── Opaque .NET types ───────────────────────────────────────────────────────

// GrpcChannel and GrpcStream are declared in Grpc.Types as opaque Lyric types;
// the kernel maps them to the underlying .NET types at the extern boundary.

extern type NetGrpcChannel = "Grpc.Net.Client.GrpcChannel"
extern type NetGrpcStream  = "System.Collections.Generic.IAsyncEnumerator`1[System.Byte[]]"

// ─── Channel lifecycle ────────────────────────────────────────────────────────

@axiom("Grpc.Net.Client.GrpcChannel conforms to its NuGet contract")
extern package Grpc.Net.Client.Api {
  /// Open a gRPC channel to `address` (e.g. "https://host:4317").
  /// Returns Err if the address is malformed or the channel cannot be created.
  pub func netOpenChannel(address: in String): Result[GrpcChannel, String]

  /// Dispose the channel and release HTTP/2 connections.
  pub func netCloseChannel(channel: GrpcChannel): Unit
}

// ─── Unary calls ─────────────────────────────────────────────────────────────

@axiom("Grpc.Net.Client CallInvoker with pass-through marshaller conforms to its NuGet contract")
extern package Grpc.Net.Client.Unary {
  /// Make a blocking unary RPC call.
  ///
  /// `service` — fully-qualified service name, e.g.
  ///   "opentelemetry.proto.collector.trace.v1.TraceService"
  /// `method`  — unqualified method name, e.g. "Export"
  /// `payload` — protobuf-encoded request body
  /// `timeoutMs` — call deadline; 0 means no timeout
  /// `metadata`  — comma-separated "key:value" pairs for gRPC metadata headers
  ///
  /// Returns the protobuf-encoded response body on success, or a GrpcStatus on
  /// RPC error (non-OK gRPC status or transport failure).
  pub func netCallUnary(
    channel:    GrpcChannel,
    service:    in String,
    method:     in String,
    payload:    in slice[Byte],
    timeoutMs:  in Int,
    metadata:   in String
  ): Result[slice[Byte], GrpcStatus]
}

// ─── Server-streaming calls ───────────────────────────────────────────────────

@axiom("Grpc.Net.Client server-streaming CallInvoker conforms to its NuGet contract")
extern package Grpc.Net.Client.Stream {
  /// Start a server-streaming RPC.  Returns a GrpcStream handle that yields
  /// successive response messages.  Call nextStreamMessage to advance.
  pub func netOpenServerStream(
    channel:   GrpcChannel,
    service:   in String,
    method:    in String,
    payload:   in slice[Byte],
    timeoutMs: in Int,
    metadata:  in String
  ): Result[GrpcStream, GrpcStatus]

  /// Read the next message from a server-streaming response.
  /// Returns Some(bytes) while messages remain; None at end of stream.
  /// Returns Err on transport or RPC error.
  pub func netNextStreamMessage(stream: GrpcStream): Result[Option[slice[Byte]], GrpcStatus]

  /// Close and release a GrpcStream.
  pub func netCloseStream(stream: GrpcStream): Unit
}
