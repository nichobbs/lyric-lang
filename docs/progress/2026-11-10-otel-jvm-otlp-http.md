# lyric-otel: OTLP/HTTP on the JVM, unimplemented surface removed (#8953)

Part of the ecosystem remediation (docs/71, D552 item 2).

- `lyric-otel/src/_kernel/jvm/otlp_kernel.l` was an always-`Err` stub. It is
  now a real transport: `java.net.http.HttpClient` with
  `BodyPublishers.ofByteArray`, posting the pure-Lyric codec output with
  `Content-Type: application/x-protobuf`, the configured headers and a request
  deadline. `Std.Http` was checked first and cannot carry the payload: its
  request bodies are UTF-8 `String`s, which corrupt protobuf bytes >= 0x80.
- `OTel.Otlp` no longer gates `configureOtlp*` on the target; the "jvm always
  fails" branch is gone.
- Removed `OtlpProtocol.Grpc` and `configureOtlpLogs`. Both were verified to
  exist only as always-`Err` entry points. `OtlpProtocol` keeps the single case
  `HttpProtobuf` so `OtlpExporterConfig` and `defaultConfig()` stay source
  compatible. No feature flag became meaningless; `dotnet`/`jvm` still select
  the kernel.
- Tests: `tests/otlp_jvm_collector_tests.l` (new, jvm-only) drives
  `flushOtlpAsync` against an in-process `ServerSocket` collector and asserts
  the request line, content type, configured header, the byte-exact encoded
  body, metrics, a 503 followed by a successful retry, a hung collector
  hitting the deadline, and a rejected header. `otlp_transport_tests.l` is now
  target-neutral and passes on both targets; the dotnet kernel's own error
  text moved to `otlp_net_kernel_tests.l`.
- `scripts/ci/jvm-ecosystem-suites.sh` runs the `otel` suite on `--target jvm`.
- README, book chapter 29 matrix row, docs/57, docs/71 and CLAUDE.md updated.
