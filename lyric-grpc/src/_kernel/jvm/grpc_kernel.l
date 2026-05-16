/// Grpc.Kernel.Jvm — JVM extern boundary for gRPC client and server (Phase 6).
///
/// Mirrors Grpc.Kernel.Net using io.grpc:
///   Client: io.grpc.ManagedChannel + ClientCalls with pass-through MethodDescriptor<byte[],byte[]>
///   Server: io.grpc.Server (Netty transport)
///
/// Not compiled today — present to drive API parity with the .NET kernel.
/// See docs/18-jvm-emission.md and docs/37-grpc-proto-sketch.md §8.2.

@cfg(feature = "jvm")
package Grpc.Kernel.Jvm

import Grpc.Types
import Std.Core

// ─── Opaque JVM types ─────────────────────────────────────────────────────────

extern type NetGrpcChannel = "io.grpc.ManagedChannel"
extern type NetGrpcStream  = "java.util.Iterator"

// ─── Client: channel lifecycle ────────────────────────────────────────────────

@axiom("io.grpc.ManagedChannel and io.grpc.stub.ClientCalls conform to their Maven contracts")
extern package io.grpc.api {
  pub func netOpenChannel(address: in String): Result[GrpcChannel, String]
  pub func netCloseChannel(channel: GrpcChannel): Unit
}

// ─── Client: unary calls ──────────────────────────────────────────────────────

@axiom("io.grpc.stub.ClientCalls with pass-through MethodDescriptor conforms to its Maven contract")
extern package io.grpc.unary {
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

@axiom("io.grpc server-streaming stub conforms to its Maven contract")
extern package io.grpc.stream {
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

@axiom("io.grpc server host backed by Netty transport")
extern package io.grpc.server {
  pub func serve(
    host:               String,
    port:               Int,
    reflectionEnabled:  Bool,
    maxConnectionIdleMs: Int,
    registry:           Grpc.ServiceRegistry
  ): Unit
}

// ─── Server: rate limiting ────────────────────────────────────────────────────

@axiom("In-process rate limiter backed by Guava RateLimiter")
extern package com.google.common.util.concurrent {
  pub func checkRateLimit(
    method:            String,
    requestsPerMinute: Int,
    burstSize:         Int
  ): Bool
    requires: requestsPerMinute > 0
    requires: burstSize > 0
}
