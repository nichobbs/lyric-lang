# Native adopts the shared HTTP server driver (docs/73 slice S5, D790)

Slice S5 of `docs/73-jvm-pure-lyric-server-plan.md`; decisions in `docs/decisions/D790-native-adopts-the-shared-http-server-driver.md`.

## What shipped

- `lyric-stdlib/std/_kernel_native/http_server.l` (2018 lines) is deleted. Native serves HTTP/1.1 and h2 (ALPN) through `std/_kernel/http_server.l`, with `startListener{,Tls}WithLimits`, the connection cap and the timeouts of the other targets (closes N9.5 / #6106).
- The driver frees its per-listener and per-connection locks and semaphores (real frees on native, no-ops elsewhere): listener slots after the tasks end and the parked pullers leave (`waitingPullers`, `released`), an h2 connection's slots when the last party leaves its link (`refs`), a stream's credit when both of its sides have finished (`sides`). The connection task shuts the socket down and waits for its reader before it closes it.
- lyric-rt: per-connection TLS lock, reads that wait for the socket outside it, `SSL_MODE_AUTO_RETRY` off, `SSL_OP_IGNORE_UNEXPECTED_EOF` on server connections, `TCP_NODELAY` on every socket, `lyric_sock_listener_refuse` (and a no-op Windows twin). `Std.TcpHost.hostStopListener` on native now makes a later connect fail (#9184).
- Native TLS offers `http/1.1` only on Windows (`alpnPreference`, `@cfg(target_os = "windows")`).
- Tests: `llvm_http_server_self_test.l` has 18 cases (item C is now an h2 round trip, H joins its pullers through `tryNextContext`, R is the connection-churn case) and runs with `-fsanitize=address`; `http_server_stop_tests.l`, `tcp_host_tests.l` and `http_timeout_tests.l` run on native (`native-backend-self-tests.sh`, `native-platform-tests.sh`); `h2-smoke.sh native` is the curl/h2load/scheduler smoke.

## Root cause of the baseline's native defect

Every connection thread of the old kernel was joinable and joined only at `stopListener`, so each finished connection kept its thread stack (about 12 KB resident, two mappings) until the process hit `vm.max_map_count` at about 32 000 connections and could create no more threads. Reproduced in this session on the retired kernel (`wrk -c64 -H "Connection: close"`: 0 completed, 1.49M read errors, 412 MB RSS; `curl` loop: 12.4 KB per connection). With the shared driver 1 230 578 connections moved RSS from 3 028 kB to 4 504 kB (maps 158 to 166, 6 descriptors, 34 threads).

## How it was verified

Toolchain as in `2026-11-26-http-server-shared-driver.md`: the v0.7.15 compiler, `LYRIC_STD_PATH` and `LYRIC_RT_PATH` pointing at this tree, the compiler bundle staged with `scripts/stage-selfhosted-compiler.sh` (27 minutes here) for the compiler-hosted self-tests, the dotnet stdlib bundle rebuilt from the tree for the dotnet suites.

- Native, AddressSanitizer: `llvm_http_server_self_test.l` 18/18 (was 13/17 on the first run against the driver: the h2-refusal case and the parked-puller case describe the old kernel, and two TLS cases deadlocked on a stripe lock held across a blocking `SSL_read`, which is why the lock is per connection and `AUTO_RETRY` is off). `lyric-rt` `make test` and `make test-asan CC=gcc` pass.
- Native: `http_server_stop_tests` 13/13 (20 full runs and 40 runs of case 1 alone all passed; case 1 failed once in an earlier sequential batch of suites and was not reproduced, cause unknown), `tcp_host_tests` 16, `http_timeout_tests` 3, `http_timeout_native_tests` 21, `tcp_host_bounded_native_tests` 7, `http_server_host_tests` 15, `tls_tests` 30, `llvm_tls_self_test` 5, `llvm_http_client_self_test` 17, `llvm_stdlib_self_test` 61, and the first 14 cases of S4's `http_server_tests.l` (plaintext, keep-alive, pipelining, chunked, TLS, mTLS accept and reject; case 15 needs the Lyric HTTP client to negotiate h2, which the native client does not do).
- dotnet (bundle rebuilt): `http_server_dotnet_tests` 33, `http_server_stop_tests` 13, `http_server_host_tests` 15, `tls_tests` 30.
- Smoke: curl `--http2` 2:200, curl `--http1.1` 1.1:200, h2load 20 000 requests 0 failed, and the scheduler checks (fast stream 4 ms beside a 2 s one, chunks 1.5 s apart, half-close, stream reset) against `h2_smoke.l` on native.

Benchmarks (`scripts/ci/http-server-benchmark.sh native b1w b2w b3w b4h b5`, wrk 4.1.0 and h2load 1.59.0 from the Ubuntu archive; the old kernel measured by hand with the same wrk arguments):

| | retired kernel | shared driver |
|---|---|---|
| B1 req/s, p99 | 33 891 | 40 612, 6.45 ms |
| B2 req/s, errors | 0, 1 486 826 read errors | 13 639, 0 (p99 8.65 ms) |
| B3 req/s | 3 320 | 4 695 |
| B4 req/s | h1 only | 33 690, 0 failed (RSS 15 MB) |
| B5 trickle served, errors, p99, RSS max | 7 781, 0, 1.58 ms, 185 MB | 7 793, 0, 2.48 ms, 142 MB, 10 000 idle alive |

## Not verified

Windows (nothing of it was built here), macOS, the 30 minute soak, B7, and Undertow in the same run (the D780 figure was used). `lyric fmt` is v0.7.15's, not the tree's.
