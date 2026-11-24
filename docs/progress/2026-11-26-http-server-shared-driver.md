# The shared HTTP server driver, adopted by dotnet (docs/73 slice S3, D788)

Slice S3 of `docs/73-jvm-pure-lyric-server-plan.md`; decisions in `docs/decisions/D788-shared-http-server-driver.md`.

## What shipped

- `lyric-stdlib/std/_kernel/http_server.l` is now the shared server driver: no extern, no `@axiom`, written over `Std.HttpEngine`, `Std.TcpHost` and `Std.HttpServerHost`. Same public surface, plus `tryNextContext` and a `stopListener` that shuts connections down and waits for the listener's tasks (bounded by `LYRIC_HTTP_STOP_GRACE_MS`, default 5000). It stays under `_kernel/` until S5 (D780).
- `Std.HttpServerHost` gains `tryStartTask`, `ensureThreadCapacity(connections)`, `defaultMaxConnections` and `AcceptOutcome`/`acceptOutcome` on dotnet, the JVM and native; `Std.TcpHost` gains a no-op `hostCloseListener` on dotnet and the JVM (native already had it).
- The dotnet "serves only as many connections as the threadpool has threads" defect is fixed: the pool minimum follows the connection cap. B5 on this machine: before 0 trickle requests served and 8 errors, after 6498 served with 0 errors and 10 000 idle connections answering.
- Tests: `lyric-stdlib/tests/http_server_stop_tests.l` (13 cases, the docs/73 section 1.6 race map plus idempotence, the grace period and the two environment resolvers), one new idle-h2 stop case in `http_server_dotnet_tests.l` (33 now), three new seam cases in `http_server_host_tests.l` (15). `scripts/ci/stdlib-net-tests.sh` runs the stop tests on dotnet.
- docs: D788, `docs/17-axiom-audit.md` (the dotnet `Std.HttpServer` axiom row removed, baseline regenerated), `docs/61` (header and sections 6.2, 6.5 and 7), `docs/73` (status, S3 entry, S4 and S5 inputs), `lyric-stdlib/std/_kernel/README.md`, the `Std.HttpServer` row of book appendix B, CLAUDE.md.

## How it was verified

`make lyric` cannot finish in this container (the AOT step needs .NET 11, the SDK is 10). The toolchain was the v0.7.15 release compiler, with the stdlib bundle rebuilt from the tree under test (`lyric build --manifest lyric-stdlib/lyric.full.toml` minus the `# seed: current` rows, 95 packages, output named exactly `Lyric.Stdlib.dll`: the compiler names the assembly after the output file) and `lib/std` pointing at the tree. The pre-refactor reference was the same compiler with a bundle built from `origin/main`.

| | before | after |
|---|---|---|
| B1 req/s | 149 244, 153 276 | 149 237, 147 817, 157 355 |
| B2 req/s | 20 082, 19 261 | 19 402, 21 504, 19 145 |
| B3 req/s | 7 715, 7 397 | 19 207, 19 690, 19 888 |
| B4 req/s | 50 379, 55 250 | 65 522, 56 353, 67 119 |
| B5 trickle served / errors / threads / RSS | 0 / 8 / 247 / 300 MB | 6498 / 0 / 10 055 / 596 MB |

wrk -t4 -c64 (B1 to B3) and h2load -n200000 -c32 -m10 (B4), 20 s after a 5 s warm-up, server and generator on the same 4-core container; B5 as `scripts/ci/http-server-benchmark.sh dotnet b5`.

Suites on dotnet: `http_server_dotnet_tests` 33, `http_server_stop_tests` 13, `http_server_host_tests` 15, the h2 curl and scheduler smokes, `tls_tests` 30, `http_bytes_body_tests` 7, `http_async_concurrency_tests` 3, `http_timeout_tests` 3, `tcp_host_tests` 16, `tcp_host_tls_tests` 9, `http_tls_client_tests` 13, `tls_server_config_tests` 2, `http_version_tests` 5; lyric-web 102, lyric-ws 66, lyric-search 53, lyric-otel 56, lyric-ui 119. JVM: `http_server_host_tests` 15, `http_server_jvm_tests` 3, `tls_server_jvm_tests` 8 (still the JDK kernel). Native: `http_server_host_tests` 15, `http_timeout_native_tests` 21. `scripts/audit-axioms.sh` and `scripts/audit-kernel-stubs.sh` pass. A mutation run (the `hostShutdown` loop of `stopListener` removed) fails two stop tests.

An extra, not an acceptance: with `_kernel_jvm/http_server.l` (and then `_kernel_native/http_server.l`) removed from a copy of the stdlib, `http_server_stop_tests.l` passes 13 of 13 on `--target jvm` and `--target native` through the shared driver. S4 and S5 start from there; D788 lists what they still owe (h2 and TLS runs, the gates, ASan, releasing the per-listener primitives on native).

## Not verified, and findings for later slices

- The CI scripts were edited but not run end to end; `lyric fmt` here is v0.7.15's, not the tree's.
- The failure path of `tryStartTask` (thread creation failing) cannot be provoked on any target here.
- lyric-grpc's suite does not run in this container (NuGet restore), before or after.
- `Std.HttpServerHost.WorkerSet` is unused by the driver (D788 decision 3); its unbounded completion credits are a latent overflow for any long-lived user, recorded for S9.
