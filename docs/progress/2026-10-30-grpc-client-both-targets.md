# lyric-grpc client works on dotnet and the JVM; `extern package` stays unlowered (D281; #6592, #5409, #8527)

`lyric-grpc`'s kernels were `extern package` blocks (bare signatures, no
class behind the path), so nothing in the library ever reached a gRPC stack.
Instead of lowering `extern package` (impossible: there is no host symbol to
bind), both kernels now bind the real libraries with `extern type` and
auto-FFI, and the client is tested end to end. Decision: D281.

## Shipped

- `Grpc.Kernel.Net`: unary calls (`CallInvoker.BlockingUnaryCall`), server
  streaming (`AsyncServerStreamingCall<byte[]>`), per-call metadata
  (`Metadata`) and deadlines (`CallOptions.WithDeadline`), over a pass-through
  `Marshaller<byte[]>`. A closed channel is `FailedPrecondition`.
- `Grpc.Kernel.Jvm`: rewritten on grpc-java (`ManagedChannelBuilder`,
  `ClientCalls`, `ClientInterceptors` for metadata, `CallOptions` deadlines,
  `ClientCall.cancel` on `closeStream`), with `impl JMarshaller for
  StreamMarshaller` for the pass-through marshaller, and a `Lyric.Resilience`
  token-bucket `checkRateLimit`.
- `Grpc.Types`: `statusFromException` (host exception text to `GrpcStatus`),
  `decodeMetadata`, `parseAddress`, and a handle behind `GrpcStream`.
  `grpc.l` is no longer dotnet-only (removes the #8357 file-level cfg).
- Compiler: MSIL binds array and nested-closed-generic type arguments and
  pins a generic method's type arguments from the wrapper's declared types;
  JVM emits bridge methods for `impl <ExternInterface>` against the
  interface's class metadata.
- Stdlib: `Std.HttpEngine.H2Conn.encodeResponseTrailers` and
  `isH2ResponseTrailerListSafe`.
- Tests: `client_dotnet_tests.l` (12, pure-Lyric h2c gRPC test peer),
  `client_jvm_tests.l` (12, grpc-java `Server` peer), `rate_limit_jvm_tests.l`
  (5), 9 added to `grpc_types_tests.l`, 3 to `generic_extern_methodspec_self_test.l`,
  1 to `ffi_iface_impl_jvm_self_test.l`, 3 to `http_h2conn_tests.l`.
  `scripts/ci/jvm-ecosystem-suites.sh` now restores grpc-java for `grpc`.

## Not shipped

- Server hosting (`start`, `startHandle`, `stop`): #8642.
- Lowering or a dedicated diagnostic for the remaining `extern package`
  users: left open on #8527.
