# lyric-grpc server hosting on dotnet and the JVM (D284; #8642)

`Grpc.start`, `startHandle` and `stop` failed loudly on both targets after D281.
They now serve unary and server-streaming methods over plaintext HTTP/2.

## Shipped

- `GrpcRoute` carries a `GrpcHandler` value; `Grpc.addUnary` /
  `Grpc.addServerStreaming` replace the never-working `Grpc.addMethod`;
  `Grpc.startHandleAt` and `Grpc.serverPort` added.
- `Grpc.Kernel.Net.Server`: pure-Lyric h2c gRPC server on `Std.HttpEngine.H2Conn`
  (concurrent handlers, receive-window credit, send-window waits, graceful drain).
- `Grpc.Kernel.Jvm`: grpc-java `Server` with Lyric `impl`s of
  `ServerCalls.UnaryMethod` / `ServerStreamingMethod` and a metadata
  `ServerInterceptor`.
- `Std.TcpHost.hostLocalPort` on dotnet (parity with the native twin).
- JVM `error[J013]` for an unbridgeable overloaded extern-interface method;
  comment on the MSIL witness inference's value-type case.
- Tests: `server_tests.l` (13, both targets, library client against library
  server: echo, empty and 200 KB messages, metadata, error status with non-ASCII
  detail, handler panic, unknown method and service, client deadline, streaming,
  stream error, a 300 KB streamed message, stop, bound port, duplicate route),
  `jvm_impl_extern_class_self_test.l` (+1), dotnet client tests on ephemeral
  ports.

## Not shipped

TLS, reflection, compression, client and bidirectional streaming, server-side
deadline enforcement. A stop that overlaps a call in flight (drain) is
implemented but has no test: a test needs a second concurrently running caller
and `spawn` is degenerate-synchronous on dotnet.

## examples/product-catalog

The example registered its five methods with `Grpc.addMethod`, removed here, and so stopped compiling. It now registers them through `src/wire.l` (`ProductCatalog.Wire`): hand-written proto3 codecs on `Lyric.Proto` (field numbers from `domain.l`), an adapter per method that reads the `authorization` metadata value as the handler's `authToken`, and `registerProductService`. A test checks that malformed request bytes fail with `INVALID_ARGUMENT`. The handlers that touch the database remain untested without a Postgres instance, as before.
