# The JVM adopts the shared HTTP server driver (docs/73 slice S4, D789)

Slice S4 of `docs/73-jvm-pure-lyric-server-plan.md`; decision in `docs/decisions/D789-jvm-adopts-the-shared-http-server-driver.md` (measured table and the open B3 RSS gate are there).

## What shipped

- `lyric-stdlib/std/_kernel_jvm/http_server.l` (the JDK `com.sun.net.httpserver` kernel) is deleted; the JVM loader now reads the shared driver `_kernel/http_server.l`. h2 over ALPN, mTLS, `takeConnection`, `tryNextContext`, limits and the stop contract now exist on the JVM. No driver change was needed for the record-arity limit (#6089).
- JVM seam: `tryStartTask` catches a failed `startVirtualThread`; `Std.TcpHost` grows a connection's read buffer 16 KiB to 64 KiB when a read fills it.
- Shared file (reported for S5): `HttpListener` is `@sendable` with an `@axiom` again (S3 had made `spawn f(listener)` a T0225 error on every target), `ByteChunks` keeps the first chunk outside its list, and `respondBytesWith` writes a body of 16 KiB or more after the head instead of joining them.
- Tests: `http_server_dotnet_tests.l` is now `http_server_tests.l` (35 cases, no extern, dotnet and JVM); `http_server_jvm_tests.l` deleted (cases ported); `tls_server_jvm_tests.l` 6 cases; `tls_tests.l` expects real mTLS; `dotnet_h2_smoke.l` and scripts renamed `h2_smoke.l`, `h2-smoke.sh dotnet|jvm`, `h2-scheduler-smoke.sh`; `stdlib-net-tests.sh jvm` runs the neutral suite, stop suite and the curl smoke.
- Removed or updated: docs/17 (JVM row gone, one .NET `Std.HttpServer` row for the `@sendable` axiom, 43 + 33), docs/61, 44, 59, 73, kernel READMEs, CLAUDE.md, book appendix B, benchmark script (`jvm-nodelay` dropped) and README, `lyric-web`'s JVM kernel (imports `Std.TlsServerContext` directly; Undertow stays until S6), TIR builder-shape script.

## How it was verified

Toolchain: v0.7.15 compiler, `lib/std` a real copy of the tree, `Lyric.Stdlib.dll` rebuilt from it (as D788). JVM: `http_server_tests` 35, stop 13, host seam 15, `tls_server_jvm_tests` 6, `tls_tests` 30, `tcp_host_tests` 16, `tcp_host_tls_tests` 9, `http_timeout_tests` 3, `http_tls_client_tests` 13, `http_bytes_body_tests` 7, `tls_server_config_tests` 2, `http_version_tests` 5, `stdlib_jvm_kernels_self_test` 32, `http_version_jvm_self_test` 2; `lyric-web`, `lyric-ws`, `lyric-search`, `lyric-otel`, `lyric-grpc` suites all pass on `--target jvm` (grpc 55 cases). curl `--http2` smoke and scheduler smoke pass on JVM and dotnet. dotnet: `http_server_tests` 35, stop 13, host 15, `tcp_host_tests` 16, `tls_tests` 30, `http_timeout_tests` 3, `lyric-web` 98, `lyric-ws` 69, `lyric-search` 53, `lyric-otel` 56 pass; B1 148 796 req/s on a quiet machine (S3: 147 to 157k), B3 17 979, B4 53 188. `audit-axioms.sh` and `audit-kernel-stubs.sh` pass.

## Not verified

- B6 ran 180 s, not 30 minutes. B7 and the S5 gates not run. `lyric-ui` JVM suites and the `lyric-ecosystem` suites were not run (ecosystem sources only use the unchanged public surface). ci.yml edits, `h2-smoke.sh` inside CI, `tir-builder-shapes` and `check-workflow-size` not run end to end; `lyric fmt` is v0.7.15's.
- B3 server RSS: 1 708 MB against 769 MB (2.22x, gate 1.5x). See D789 decision 10.
- The `tryStartTask` failure path cannot be provoked.

## Issue text for the open item

Title: JVM `slice[Byte]` is a boxed array, so bulk HTTP bodies cost 4 copies of 4 bytes per byte (B3 RSS gate of docs/73 S4 missed at 2.2x). Body: JFR on the 64 KiB echo (`benchmarks/http_server`, wrk -c64) shows 1.1 MB allocated per request on the shared driver against 0.52 MB on Undertow: socket read (`byte[]` then `Byte[]`), the engine's body slice, the chunk join, and the write's unboxing, each a 256 KiB boxed array. G1 grows young to ~1 GB, RSS 1.7 GB against 0.77 GB; `-Xmx768m` gives RSS 799 MB at 98% throughput. Plan: represent `slice[Byte]` as `byte[]` in the JVM backend (nichobbs/lyric-lang#9245), then re-run B3; expected allocation parity removes the miss. Acceptance: B3 RSS within 1.5x of Undertow in `http-server-benchmark.sh`.
