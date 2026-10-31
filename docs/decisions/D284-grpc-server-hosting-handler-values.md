# D284 — gRPC server hosting: handler values, a pure-Lyric h2c server on dotnet, grpc-java on the JVM (#8642)

**Status:** shipped

## Context

D281 made the lyric-grpc client real on both targets and split server hosting
out (#8642) for two reasons: `ServiceRegistry` named handlers by string
(`GrpcRoute.handlerName`), which no target can dispatch on, and `Grpc.AspNetCore`
registers an RPC route through `BindableService` / `ServiceBinderBase`, abstract
classes a Lyric record cannot extend.

## Decision

1. **A route carries its handler.** `GrpcRoute` is `{ service, method, handler:
   GrpcHandler }` and `GrpcHandler` is `Unary(handle)` or `ServerStreaming(handle)`.
   A unary handler maps `(request bytes, request metadata)` to `Result[bytes,
   GrpcStatus]`. A server-streaming handler additionally receives `emit: (bytes)
   -> Bool` (false once the client has gone) and returns `Result[Unit,
   GrpcStatus]`. `Grpc.addUnary` / `Grpc.addServerStreaming` replace
   `Grpc.addMethod`, which never worked (no target could resolve its name), so
   removing it breaks no running code. Registering one `(service, method)` twice
   violates a `requires:`. The metadata handlers see has lowercase keys and omits
   pseudo-headers, `content-type`, `te`, `user-agent`, `grpc-*` and `-bin` keys.
2. **A handler that panics fails its call with `Internal` and no detail.** The
   panic text can carry server internals; it never reaches the client and never
   stops the server.
3. **dotnet: a pure-Lyric h2c gRPC server** (`Grpc.Kernel.Net.Server`) on
   `Std.TcpHost` and the stdlib's sans-IO `Std.HttpEngine.H2Conn`, verified by
   `Grpc.Net.Client`, an implementation it shares no code with. Per connection one
   task reads; each call's handler runs on its own task; a connection's HTTP/2
   state and writes are serialized by a monitor. Receive windows are credited as
   data arrives, so messages above the 64 KiB default window work; a sender whose
   send window is empty releases the monitor and polls until it opens, the call is
   cancelled, or 30 s pass. Request limits: one uncompressed message, at most
   4 MiB. Needed stdlib additions: `Std.HttpEngine.H2Conn.encodeResponseTrailers`
   (D281) and `Std.TcpHost.hostLocalPort` (the native twin already had it) for
   ephemeral ports.
4. **JVM: a grpc-java `Server`** (`NettyServerBuilder.forAddress`) whose routes
   are `impl`s of `ServerCalls.UnaryMethod` / `ServerStreamingMethod` over the
   client's pass-through marshaller. Request metadata reaches handlers through a
   gRPC `Context` value set by a `ServerInterceptor`, because a handler runs on an
   executor thread, not the interceptor's.
5. **API:** `Grpc.startHandleAt(registry, host, port)` (port `0` = ephemeral) and
   `Grpc.serverPort(handle)` join `start` / `startHandle` / `stop`.
   `start` serves until the process exits. `stop` stops accepting, waits up to
   `drainTimeoutMs` for calls in flight, then closes (dotnet) or cancels (JVM) the
   rest; a second stop is a no-op. Binding a taken address, or
   `reflectionEnabled = true`, panics (the signatures carry no `Result`).
   `maxConnectionIdleMs` is applied on both targets (dotnet: a read timeout that
   ignores connections with calls in flight).
6. **Out of scope, stated:** TLS, reflection, compression, client and
   bidirectional streaming, and server-side `grpc-timeout` enforcement (the
   client's deadline cancels the call; the handler is not interrupted).

## Compiler follow-ups folded in

- The JVM backend reports `error[J013]` when an `impl <ExternInterface>` method
  matches none of several same-name, same-arity abstract overloads, instead of
  skipping the bridge and failing with `AbstractMethodError` at run time.
- The MSIL witness-inference comment records why value-type generic wrapper
  positions keep the `System.Object` convention.
- The dotnet client test peer binds ephemeral ports (`hostLocalPort`) instead of
  fixed ones.
