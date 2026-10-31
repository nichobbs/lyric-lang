# D281 — `extern package` is not lowered; the gRPC kernels bind real classes with `extern type` and auto-FFI (#6592, #5409, #8527)

**Status:** shipped (client). Server hosting is tracked in #8642.

## Context

`lyric-grpc`'s kernels were written as `extern package <path> { pub func ... }`
blocks: bare signatures with an `@axiom` trust annotation and no body. The
issues (#6592 dotnet, #8527 JVM) read the problem as "`extern package` members
have no codegen lowering" (a no-op on MSIL, J002 on the JVM) and asked for the
lowering.

Reading the blocks shows lowering cannot work. Their paths name no class:
`io.grpc.api`, `io.grpc.unary`, `io.grpc.server.managed`,
`com.google.common.util.concurrent`. Their members take Lyric types
(`GrpcChannel`, `Result[slice[Byte], GrpcStatus]`, `Grpc.ServiceRegistry`) that no
JDK, Maven or NuGet class accepts. There is no `io.grpc.api.netOpenChannel` to
`invokestatic`, so an `invokestatic` lowering would fail at link time instead of
at compile time. The block records what the author wished a library offered; it
is not a binding. The same conclusion is already in the tree: `lyric-auth`'s JVM
kernel was rewritten off `extern package` for the same reason (its header says
the form is "a confirmed no-op in both the type checker and the MSIL/JVM
codegens"), and the dotnet gRPC kernel had already been reduced to honest
`Err`-returning stubs. The compiler gaps that blocked a real dotnet binding
(#6581: a generic-declaring-type constructor with a closed-generic parameter, a
generic-method call) were fixed in #6981.

## Decision

1. **`extern package` gets no lowering, on any target.** A body-less member
   cannot know the host symbol it stands for. Native bindings are written with
   `extern type` / `import extern` plus `@externTarget` auto-FFI (docs/47,
   docs/48, docs/42 and docs/66), whose signatures the compiler checks against
   the real class metadata. The remaining `extern package` users are tracked
   under #8527; each becomes either a real binding or deleted dead code.
2. **`Grpc.Kernel.Net` and `Grpc.Kernel.Jvm` are written against the real
   libraries** and tested end to end:
   - dotnet: `Grpc.Net.Client` / `Grpc.Core.Api`. A pass-through
     `Marshaller<byte[]>`, `Method<byte[],byte[]>`, `CallInvoker.BlockingUnaryCall`
     and `AsyncServerStreamingCall<byte[]>` carry raw protobuf bytes (compose
     with `lyric-proto`); `RpcException` text is mapped to `GrpcStatus` by
     `Grpc.Types.statusFromException`.
   - JVM: grpc-java. `ManagedChannelBuilder`, `ClientCalls.blockingUnaryCall` /
     `blockingServerStreamingCall` and `ClientInterceptors` (call metadata) over a
     `MethodDescriptor.Marshaller<InputStream>` implemented in Lyric
     (`impl JMarshaller for StreamMarshaller`). The message type is the stream
     itself so no `slice[Byte]` crosses an `impl` method (the backend lowers an
     `impl` parameter against the real `byte[]` but ordinary code treats a slice
     as `Object[]`).
   - Both keep the `Int`-keyed handle registry the platform-neutral
     `GrpcChannel` / `GrpcStream` opaque types wrap.
3. **Compiler changes the bindings needed** (each with a regression test):
   - MSIL `argFqnToMsil` binds an array type argument
     (`Marshaller`1[System.Byte[]]`) and a closed generic nested in another
     (`ConcurrentDictionary`2[System.Int32,AsyncServerStreamingCall`1[System.Byte[]]]`)
     instead of interning a TypeRef named by the bracketed text.
   - MSIL generic-method witness inference
     (`inferGenericExternWitnessesMsil`): a method-own type parameter with no
     `T[]` position is instantiated from the wrapper's declared types when they
     agree (a bare position declared as an array, an argument of a closed
     generic the wrapper names), instead of always `System.Object`. Anything
     that disagrees keeps the `Object` convention, so existing bindings are
     unchanged.
   - JVM codegen emits the synthetic bridge method for an `impl
     <ExternInterface>` whose method spells a narrower type than the
     interface's erased slot, reading the slot from the interface's class
     metadata (`Comparator<T>.compare(Object,Object)`,
     `MethodDescriptor.Marshaller<T>`). Lyric interfaces already had this
     (#8426).
   - `Std.HttpEngine.H2Conn.encodeResponseTrailers` and
     `isH2ResponseTrailerListSafe`: the HTTP/2 server FSM could send response
     HEADERS and DATA but never the closing trailer block gRPC needs. It also
     lets a pure-Lyric gRPC server exist (#8642).
4. **`Grpc` is no longer dotnet-only.** The file-level
   `@cfg(target = "dotnet")` added in #8357, because the JVM kernel was a
   sketch, is removed from `grpc.l`; each public function already carries a
   `@cfg(feature = ...)` body per kernel. `Grpc.Aspects` stays dotnet-only (its
   `lyric-auth` and `lyric-resilience` wiring has no JVM test yet).
5. **Server hosting is out of this change.** It needs two things the client does
   not: a handler value in `ServiceRegistry` (a string `handlerName` has no
   dispatch mechanism on either target), and a way to host a route (dotnet:
   `Grpc.AspNetCore` needs a `BindableService` subclass, which a Lyric record
   cannot be; JVM: `ServerCalls` handlers, now expressible). `serve`,
   `netStartHandle` and `netStopHandle` fail loudly on both targets, naming #8642.

## Consequences

- `Grpc.openChannel` / `closeChannel` / `callUnary` / `openServerStream` /
  `nextMessage` / `closeStream` / `checkRateLimit` work on dotnet and the JVM.
  The test peers are a pure-Lyric h2c gRPC server on `Std.HttpEngine.H2Conn`
  (dotnet) and a grpc-java `Server` (JVM).
- The JVM rate limiter is the `Lyric.Resilience` token bucket (`requestsPerMinute
  + burstSize` permits, refilled at `requestsPerMinute`), the algorithm
  `Web.Kernel.Runtime` already uses on that target; the dotnet kernel keeps its
  two-window `SlidingWindowRateLimiter` pair. The numbers differ at the margin
  (documented in `lyric-grpc/README.md`).
- JVM address validation is stricter: `http(s)://host[:port]` with no path
  (`Grpc.Types.parseAddress`), because grpc-java targets carry none.
- Binding a Lyric `GrpcStatus` from host exception text depends on the documented
  `Status(StatusCode="...", Detail="...")` (grpc-dotnet) and `CODE: description`
  (grpc-java) message formats; anything else is `Unknown` carrying the whole
  message.
