# `Std.TcpHost` fit to carry a server on dotnet and the JVM (docs/73 slice S1, D621)

Slice S1 of `docs/73-jvm-pure-lyric-server-plan.md`. Design and rationale are in `docs/decisions/D621-tcphost-server-ready.md`; this note records what shipped, how it was verified and the benchmark numbers.

## What shipped

- JVM `hostRead`: a per-connection 16 KiB `ByteBuffer` filled in place by one `InputStream.read(buffer.array(), 0, n)`; only the received bytes leave as a fresh slice. No `ByteArrayOutputStream`, no `available()`/`readNBytes()`, correct on `SSLSocket` streams (the module header explains why).
- JVM write timeout: one shared watchdog virtual thread (50 ms sweep) over a registry of per-connection guards instead of a virtual thread per write. A timed-out write closes the connection with the same `write timed out: the peer accepted no data for N ms` text as before. Progress is chunk-granular (a write of at most 64 KiB must finish within the limit, a larger one gets a fresh window per 64 KiB chunk), documented in the module header and the language reference.
- `hostShutdown(conn)` on dotnet (`Socket.Shutdown(Both)`) and the JVM (`shutdownInput`/`shutdownOutput` on the underlying plain socket, also for TLS), matching native's contract. Additive; the `Std.TcpHost` surface is now identical on the three targets.
- dotnet: `TCP_NODELAY` is set on every connection (the JVM kernel already did). Without it a multi-segment echo stalled on Nagle against delayed ACK: the 256 KiB echo ran at 9 MiB/s and now runs at about 950 MiB/s.
- Import cycle broken: the server `SSLContext` construction moved to the JVM-only package `Std.TlsServerContext` (`_kernel_jvm/tls_server_context.l`), imported by `Std.TcpHost` and re-exported by `Std.HttpServer` (`pub use`), whose public surface is unchanged. The `@axiom` of `Std.HttpServer`'s JVM kernel was narrowed to what it still uses; docs/17 sections 18 and 19 updated (33 JVM `@axiom` files).
- `hostConnect` constructs its `Socket` inside the `try`; a failure while wrapping an accepted or connected socket closes it.
- Listen backlog: JVM and native 128, dotnet SOMAXCONN (clamped by the OS); recorded, not changed. No `hostSetKeepAlive` (D621 point 7).

## Tests

`lyric-stdlib/tests/tcp_host_tests.l` (16 tests, dotnet and JVM): the existing eight plus shutdown ends a blocked read, shutdown ends a write blocked on a stalled peer, a write timeout ends a write on a peer that accepts nothing, a write timeout does not cut off a draining peer, `maxBytes` is honoured, 3000 small messages, a 4 MiB round trip with both sides streaming, and four concurrent connections. `tcp_host_tls_tests.l` (9 tests): shutdown ends a read blocked on a TLS connection. Both are already in `scripts/ci/stdlib-net-tests.sh`; no `ci.yml` change.

Verified on this branch with the worktree's own `./bin/lyric` (dotnet and JVM): `tcp_host_tests`, `tcp_host_tls_tests`, `http_timeout_tests`, `http_server_dotnet_tests` (dotnet, 32), `http_server_jvm_tests` and `tls_server_jvm_tests` (JVM), `http_tls_client_tests`, `http_version_tests`, the `lyric-ws` and `lyric-web` manifests (dotnet), `stdlib_jvm_kernels_self_test` (JVM). Native (unchanged code): `tcp_host_bounded_native_tests`, `http_timeout_native_tests`, `llvm_http_server_self_test` (17), `llvm_tls_self_test` (5).

## Benchmark (B1 transport microbenchmark)

`benchmarks/tcp_host/tcp_loopback.l`, loopback echo through `Std.TcpHost` alone (server task echoes, main thread is the client), best of three rounds after a warm-up pass, 4-core container, JDK 21, .NET 10, native with clang. `tcp.*` is without an I/O timeout, `tcp_timeout.*` with a 30 s I/O timeout on both ends (on the JVM that arms the write watchdog around every write).

| Figure | dotnet | JVM new | JVM before (origin/main) | native |
|---|---|---|---|---|
| ping, 1 byte (us, lower is better) | 45.2 | 53.6 | 53.3 | 28.7 |
| echo 64 B (MiB/s) | 1.36 | 1.13 | 1.12 | 1.98 |
| echo 1 KiB (MiB/s) | 21.0 | 15.8 | 14.6 | 25.2 |
| echo 16 KiB (MiB/s) | 264 | 75.5 | 46.2 | 103 |
| echo 256 KiB (MiB/s) | 934 | 110 | 77.6 | 138 |
| timeout: ping (us) | 44.5 | 56.3 | 73.0 | 29.6 |
| timeout: echo 64 B (MiB/s) | 1.34 | 1.07 | 0.81 | 1.97 |
| timeout: echo 1 KiB (MiB/s) | 21.3 | 15.8 | 11.0 | 25.6 |
| timeout: echo 16 KiB (MiB/s) | 282 | 75.0 | 45.4 | 107 |
| timeout: echo 256 KiB (MiB/s) | 973 | 130 | 70.9 | 180 |

Acceptance of docs/73 S1 is "JVM read/write path no slower than 2x dotnet loopback". Result, plainly: it is met for latency (1.2x) and for messages up to 1 KiB (1.3x), and it is **not met for 16 KiB messages (3.5x slower) or 256 KiB messages (8.5x slower)**. The write watchdog is not the cost (the timeout rows equal the no-timeout rows, and are 1.3 to 1.8x better than the old thread-per-write design). A JFR profile of the benchmark puts nearly all CPU in the `Object[]` to `byte[]` and `byte[]` to `Object[]` conversion loops inside `hostRead` and `hostWrite`: a Lyric `slice[Byte]` is an `Object[]` of boxed `Byte` on this target, so every byte received is boxed and every byte sent is unboxed one element at a time (about 2 to 3 ns per byte), while the JDK socket calls themselves barely register. Tried: reading straight into a reusable buffer (done, the 1.4 to 1.6x gain over before), removing the stream wrappers and `available()` probe (done), a single `copyOfRange` per read (done); GC choice (ParallelGC gains about 15 percent, SerialGC is much worse). What would close it is not in the transport: representing `slice[Byte]` as `byte[]` on the JVM backend (a compiler-wide change), or a bulk conversion intrinsic. HTTP reads of at most 16 KiB with typical request sizes sit in the rows that meet the bar; the gap is for bulk bodies. This is left open for the docs/73 S0 baseline and the S4 gate to judge against real HTTP workloads; no issue could be filed from this session.

## Left open

- The 16 KiB and larger throughput gap above (compiler-level slice representation).
- #9184 (native `hostStopListener` leaves the fd open) is not fixed: the stop/close split is deliberate (#6883) and changing it alters every native server's shutdown path, so `tcp_host_tests.l` and `http_timeout_tests.l` stay off the native lists. It belongs with docs/73 S5.
- Native POSIX connections do not set `TCP_NODELAY` (Windows does); not changed here.
