/// JVM kernel boundary for lyric-grpc (Phase 6).
///
/// Mirrors Grpc.Kernel.Net using io.grpc.ManagedChannel and
/// io.grpc.stub.ClientCalls with a pass-through MethodDescriptor<byte[], byte[]>.
///
/// Not compiled today — present to drive API parity with the .NET kernel.
@cfg(feature = "jvm")
package Grpc.Kernel.Jvm

import Grpc.Types
import Std.Core

extern type NetGrpcChannel = "io.grpc.ManagedChannel"
extern type NetGrpcStream  = "java.util.Iterator"

@axiom("io.grpc.ManagedChannel and io.grpc.stub.ClientCalls conform to their Maven contracts")
extern package io.grpc.api {
  pub func netOpenChannel(address: in String): Result[GrpcChannel, String]
  pub func netCloseChannel(channel: GrpcChannel): Unit
}

@axiom("io.grpc.stub.ClientCalls with pass-through MethodDescriptor conforms to its Maven contract")
extern package io.grpc.unary {
  pub func netCallUnary(
    channel:   GrpcChannel,
    service:   in String,
    method:    in String,
    payload:   in slice[Byte],
    timeoutMs: in Int,
    metadata:  in String
  ): Result[slice[Byte], GrpcStatus]
}

@axiom("io.grpc server-streaming stub conforms to its Maven contract")
extern package io.grpc.stream {
  pub func netOpenServerStream(
    channel:   GrpcChannel,
    service:   in String,
    method:    in String,
    payload:   in slice[Byte],
    timeoutMs: in Int,
    metadata:  in String
  ): Result[GrpcStream, GrpcStatus]

  pub func netNextStreamMessage(stream: GrpcStream): Result[Option[slice[Byte]], GrpcStatus]
  pub func netCloseStream(stream: GrpcStream): Unit
}
