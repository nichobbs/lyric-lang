# HTTP server baseline, spikes and gates (docs/73 slice S0, D780)

Slice S0 of `docs/73-jvm-pure-lyric-server-plan.md`. No product code changed. This note records what was built, how it was measured, the numbers, the four spike outcomes, and the defects the baseline exposed. The decisions it supports are in `docs/decisions/D780-http-server-baseline-and-gates.md`.

## What shipped

- `benchmarks/http_server/`: `server.l` (the server under test over `Std.HttpServer`, dotnet engine, JVM JDK-server kernel and native), `server_web.l` (the same routes through `lyric-web`, Undertow on the JVM), `loadgen.l` (an HTTP/1.1 load generator in Lyric over `Std.TcpHost` and `Std.Task`), `ws_server.l` and `ws_clients.l` (B7), a README, and `spikes/` (throwaway, documented, builds).
- `scripts/ci/http-server-benchmark.sh <dotnet|jvm|jvm-nodelay|native|undertow> [b1 b2 b3 b4 b5 b6 b1w b2w b3w b4h]`: builds the server and the generator, starts the server, samples its RSS, threads and fds once a second, runs the scenarios and prints `target.scenario.key=value` lines. Not in `ci.yml` (about 500 bytes of headroom, `check-workflow-size.sh`); meant to be run by hand or from a nightly job.

## Environment and toolchain, stated plainly

- One container: 4-core Intel Xeon 2.1 GHz, 15 GB, JDK 21.0.12, .NET SDK and runtime 10.0.115/10.0.15, clang 18.1.3. Server and generator share the machine.
- `make lyric` could not finish here: the stage-1 build works, but the AOT entry project fails with NETSDK1045 because D622 moved the compiler to .NET 11 and the container has only the .NET 10 SDK. There is therefore no `./bin/lyric` built from this tree. The toolchain used is the **v0.7.15 release compiler** (published 2026-11-19, the `stage0-publish` seed) with `lib/std` replaced by this tree's `lyric-stdlib/std` (JVM and native compile stdlib from source), `lib/Lyric.Stdlib.dll` replaced by the bundle that stage 1 built from this tree's sources, and `lyric_rt.a` rebuilt from `lyric-rt/`. All kernels measured are therefore those of `origin/main` at `08f8f1a44` (D621's `Std.TcpHost` work included); the compiler is v0.7.15, five days older than `main`. A first full run against the unmodified v0.7.15 install was discarded: its compiled dotnet bundle predates D621 (no `TCP_NODELAY`), which showed up as a 43 ms h2 latency floor (1.1k req/s against 12.7k) and would have been recorded as a dotnet defect.
- `wrk` 4.1.0 and `h2load` 1.59.0 (nghttp2) are not installed. They were obtained with `apt-get download` from `archive.ubuntu.com` (reachable from the container) and extracted with `dpkg-deb -x` into a scratch directory, not installed. The script uses them when on `PATH`.
- Method: 64 connections (`-c64`), 5 s warm-up then 20 s measured (wrk: a throwaway warm-up run, then `--latency`), one run per cell; the 60 s pause between targets lets TIME_WAIT sockets drain. Single runs on a shared 4-core container: treat differences under about 10% as noise.

## Numbers

All figures are one run each. Server RSS is the sampled maximum.

### B1 to B4, req/s with p50 / p99 latency in ms

| | dotnet engine | JDK server (as shipped) | JDK server, `nodelay=true` | Undertow (lyric-web) | native |
|---|---|---|---|---|---|
| B1 hello, keep-alive, wrk | 152 858, 0.33 / 12.21 | 1 440, 43.97 / 48.14 | 71 164, 0.80 / 4.09 | 91 298, 0.57 / 7.16 | 40 794, 1.78 / 6.14 |
| B1, Lyric generator | 79 757, 0.61 / 3.88 | 1 426, 44.11 / 50.21 | 43 843, 1.34 / 3.72 | 47 900, 1.18 / 5.64 | 33 163, 1.81 / 6.73 |
| B2 connection per request, wrk | 21 071, 1.38 / 15.88 | 35 634, 1.01 / 3.90 (*) | 35 851, 1.02 / 4.01 (*) | 34 602, 1.41 / 6.49 | 0 (**) |
| B2, Lyric generator | 16 227, 2.98 / 16.46 | 18 678, 2.48 / 8.45 | 19 365, 2.39 / 8.45 | 25 679, 1.90 / 13.00 | 0 (**) |
| B3 echo 64 KiB, wrk (MiB/s) | 7 755 (485), 6.99 / 68.19 | 9 425 (589), 6.51 / 13.25 | 10 189 (637), 5.98 / 12.88 | 7 460 (466), 7.08 / 45.32 | 4 195 (262), 18.09 / 47.45 |
| B3, Lyric generator (MiB/s) | 4 948 (309), p99 72.6 | 5 325 (333), p99 24.6 | 6 041 (378), p99 23.4 | 1 998 (125), p99 132.0 | 2 986 (187), p99 63.8 |
| B4 h2 over TLS, h2load, 200 000 requests, 32 conns x 10 streams: req/s, mean ms | 58 379, 5.14 | h1 only | h1 only | 34 371, 8.77 | h1 only |
| B4, `curl --http2 --parallel`: req/s, p50 / p99 | 12 709, 1.52 / 4.54 | h1 only | h1 only | 11 392, 1.79 / 14.82 | h1 only |

(*) `wrk` counts 713 269 and 717 483 "read errors" on these two: the JDK server closes after a `Connection: close` request without answering with a `Connection: close` header, which `wrk` treats as an error. The Lyric generator's B2 run against the same servers has zero errors, so this is a protocol-visible difference, not lost requests.
(**) The native server completed no request at 64 connections (`wrk`: 1.37M reads that ended in a reset; Lyric generator: all errors). It works with 8 or fewer connections (about 9.7k req/s). See the defects.

Server RSS maximum in MB, B1 / B2 / B3 (wrk): dotnet 186 / 187 / 281; JDK 226 / 390 / 1 139; JDK nodelay 400 / 411 / 1 163; Undertow 419 / 421 / 938; native 6 / 412 / 99. Threads: dotnet 110 to 232, JVM servers 28 to 59, native 49 to 98. B4 RSS: dotnet 209, Undertow 536.

### B5, 10 000 idle keep-alive connections plus 8 trickling connections for 20 s

| | dotnet | JDK | JDK nodelay | Undertow | native |
|---|---|---|---|---|---|
| server RSS max MB / threads max / fds max | 241 / 248 / 10 066 | 253 / 28 / 10 017 | 261 / 28 / 10 017 | 259 / 35 / 10 034 | 185 / 10 042 / 10 014 |
| trickle requests, errors, p99 ms | 0, 8, - | 3 615, 0, 48.2 | 7 694, 0, 3.68 | 7 728, 0, 3.23 | 7 781, 0, 1.58 |
| idle connections opened / answering afterwards | 10 000 / 10 000 | 10 000 / 10 000 | 10 000 / 10 000 | 10 000 / 10 000 | 10 000 / 10 000 |

The Std.HttpServer engines cap concurrent connections at `LYRIC_HTTP_MAX_CONNECTIONS` (default 1 000, #6071), so the script raises it to 11 000 for B5 on dotnet and native; Undertow and the JDK server have no cap.

dotnet's trickle result is a finding, not noise: the 10 000 handler tasks queue on a threadpool that grew to 248 threads, so only the first connections are served; new connections got nothing for 20 s. The idle connections answered in the closing pass only because closing earlier ones freed threads for the queued tasks (an inference from the order, consistent with the thread count; not separately proven).

### B6, soak shortened to 180 s (the full gate is 30 minutes)

Offered load is half of the same run's B1 rate (Lyric generator) from 64 connections, plus two connections doing connect, request, close in a loop. Only a short run was possible in this session; the 30 minute gate of D780 is **not measured**.

| | dotnet | JDK nodelay | Undertow | native |
|---|---|---|---|---|
| soak req/s (b1 rate it is half of) | 43 581 (79 270) | 24 903 (46 846) | 25 835 (48 640) | 18 456 (32 790) |
| errors, soak / churn | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 1 119 042 |
| churn requests completed | 591 002 | 364 472 | 289 257 | 32 621 |
| p99 ms | 2.92 | 3.33 | 4.22 | 3.42 |
| RSS max MB, last sample MB | 186, 186 | 276, 266 | 294, 294 | 412, 412 |
| threads max / fds max / fds at end | 129 / 130 / 58 | 28 / 76 / 9 | 59 / 96 / 26 | 100 / 73 / 6 |
| RSS drift, last sample against sample 60 | 0.3% | 0.1% | 0.2% | 0.0% |

No leak signal on the three managed servers in 180 s. Native's RSS reached 412 MB within seconds of the churn starting and stayed there, with the churn connections then failing (see defects).

### B7, 1000 WebSocket clients, 1 KiB broadcast at 10 Hz for 30 s (clients on the JVM)

| | dotnet pure-Lyric kernel, default threadpool | same, `MinThreads=1500` | Undertow (JVM) |
|---|---|---|---|
| connected of 1000 | 125 | 999 | 997 |
| delivery latency p50 / p99 / max ms | 1 / 2 / 62 (125 clients) | 7 / 49 / 87 | 33 / 76 / 421 |
| messages received per connection, min / max | - | 15 / 299 | 293 / 294 |
| server RSS max MB, threads max | 92, 81 | 240, 1 545 | 233, 27 |

Latency is the receiving clock minus the broadcast's start timestamp (one machine, 1 ms resolution), so it includes the serial send over 1000 connections. The dotnet minimum of 15 messages is connections that joined late, as the handshakes ramped over about 25 s even with the floor raised. The JVM has no pure-Lyric server yet, so there is no JVM cell for it; that is what S7a produces.

## Spike outcomes

(a) **Reduced driver and the `Std.HttpServer` plus `Std.HttpServerHost` split: passes on all three targets.** `spikes/split/` is an accept loop, a counting-semaphore FIFO of ready contexts with a one-shot semaphore per request and an h1 keep-alive connection loop in shared Lyric (`Std.SpikeServer`), over a three-twin kernel seam (`Std.SpikeServerHost`: `startTask`, counting semaphore). The driver sends three requests down one keep-alive connection and checks each reply. `run.sh` prints `SPIKE-OK` on the JVM, native and dotnet. What it confirmed: `ref record`s with `var` fields (`SpikeListener.stopping`, `SpikeContext.body`) compile and run on every target; closures handed to the seam run on dotnet `Task.Run`, JVM virtual threads (a `Runnable` record) and native `Std.Task`; no `try`, `inout` or `String[i]` is needed. Package loading: the JVM and native source loaders take the new packages from `LYRIC_STD_PATH` with no change; dotnet needs both packages registered in `lyric-stdlib/lyric.full.toml` and the bundle rebuilt (it links the compiled `Lyric.Stdlib.dll`, so a new package is `TypeLoadException` until then), and `--internal-perpackage-build` then emits `Lyric.Stdlib.SpikeServer.dll` and `Lyric.Stdlib.SpikeServerHost.dll`; the JVM toolchain refuses per-package emit by design (one bundled JAR). Two surprises, both recorded in D780: the seam function cannot be named `spawn` (reserved word, P0051), and a top-level `std/<name>.l` is not shadowed by a `_kernel_jvm/<name>.l` or `_kernel_native/<name>.l` of the same basename (`run.sh` ends with that check: JVM `T0001 duplicate name`, native a misleading `N0007`), so the shared driver has to stay at `_kernel/http_server.l` until the native kernel is gone. The #5932 hazard of the plan is stale: D-progress-889 fixed it. The native seam in the spike spawns through `Std.Task` rather than a raw `pthread_create`; the closure-retain discipline of `_kernel_native/http_server.l` (#6797) is not exercised and stays an S2 task.

(b) **JDK 21 virtual-thread pinning with `SSLSocket`: not pinned.** `spikes/pinning/pinning.sh`: a TLS echo server over `Std.TcpHost` (handshake and read on a virtual thread per connection) against 32 concurrent TLS clients that all hold their connection open while the others are served. With the default scheduler and `-Djdk.tracePinnedThreads=full`: 32 of 32 served, no pinned stack in the server output. With a one-carrier scheduler (`parallelism=1`, `maxPoolSize=1`): 32 of 32 served, no pinned stack; a pinned read would have wedged the only carrier. JDK 21.0.12 only; no negative control was run (a deliberately pinning server), so the evidence is "no deadlock and no trace", not a demonstration that the detector fires.

(c) **Cross-error-type JVM miscompile at `web.l` ~2455: not reproduced.** `spikes/crosserror/run.sh`: the exact shape of the shared `Web.serveTls` (match a `Result[_, Std.HttpServer.TlsListenError]` from `startListenerTls` inside a function returning `Result[_, ServeTlsError]`, here forced to the `Err` path with `requireClientCert` and no `clientCa`) runs correctly on the JVM, and so does a two-package user-union variant that matches the inner error by function call, by case in a nested `match`, and as a nested pattern `case Err(InvalidConfig(reason))`. The comment in `web.l` describes the #5903 family, which is fixed in the compiler used here. Two related facts: the JVM `TlsListenError` still has only `NotSupportedOnTarget` and no `.message` (the shared `serveTls` calls `TlsListenError.message`; S4 adds it), and S6 should keep a JVM test of the misconfiguration path. No issue to file; the stale comment goes in S6.

(d) **Tooling availability.** `wrk`, `h2load`/`nghttp` are not installed in the container and no workflow installs them; both come from `archive.ubuntu.com` (`apt-get download`, extracted, used here) and `nghttp2-client` is a plain `apt-get install` on a hosted ubuntu runner (the workflow already runs `sudo apt-get install` in several jobs). `h2spec` (a Go binary) is not referenced anywhere in the repository and its availability was not checked. Docker: the client is installed in the container but the daemon socket is absent, and no workflow job uses a container image or `docker run` today, so the Autobahn nightly of S8 needs a job that starts Docker on a hosted runner: unverified. PyPI is reachable; Maven Central is reachable (the Undertow restore ran). GitHub-hosted runner labels in `ci.yml`: `ubuntu-latest` and the `CI_HEAVY_RUNNER` variable (self-hosted runner class not visible from here).

## Defects found by the baseline (issue texts, to be filed; this session cannot open GitHub issues)

1. **`Std.HttpServer` JVM kernel: 44 ms stall per keep-alive request.** `com.sun.net.httpserver` leaves Nagle on (`sun.net.httpserver.nodelay` defaults to false); the response is two writes (headers, body) and the second waits for the client's delayed ACK. Repro: `scripts/ci/http-server-benchmark.sh jvm b1w` gives 1 440 req/s, p50 44 ms; `jvm-nodelay` (same jar, `-Dsun.net.httpserver.nodelay=true`) gives 71 164 req/s, p50 0.8 ms. Fix until S4 removes the kernel: set the property before the first `HttpServer` is created.
2. **`Std.HttpServer` native kernel: no request completes under connection-per-request load, and memory is not returned.** `wrk -t4 -c64 -H "Connection: close"` against `benchmarks/http_server/server.l --target native`: 0 responses, 1.37M read errors; RSS climbs to about 412 MB (about 12 KB per accepted connection) and stays. 8 concurrent connections work (about 9.7k req/s, RSS still grows). The churn client of B6 completes 32 621 requests and then fails. Not root-caused (ephemeral-port exhaustion on the client side, listen backlog 128 and a per-connection leak are all candidates; the leak is suggested by the flat 412 MB plateau).
3. **`Std.HttpServer` dotnet kernel serves only as many connections as the threadpool has threads.** With 10 000 idle keep-alive connections held (cap raised), a trickle of 8 new connections got 0 responses in 20 s (248 threads). Each connection occupies a threadpool thread blocked in a read; the minimum is raised to 200 only.
4. **`lyric-ws` dotnet kernel: only 125 of 1000 clients complete the handshake with the default threadpool.** `Std.HttpServer`'s kernel raises the minimum thread count (`setMinThreads(200, 200)`), the ws kernel does not; with `System.Threading.ThreadPool.MinThreads=1500` in the runtimeconfig 999 of 1000 connect.
5. **Native diagnostic when two files of one package declare the same name:** `N0007 ... type 'SpikeListener' is not yet supported for --target native (Phase N1 lowers scalars and String only)` where the JVM reports `T0001 duplicate name 'spikePort'`. Repro: `benchmarks/http_server/spikes/split/run.sh`, last step.

## What changes in the plan

docs/73 is amended in place: status header, section 1.2 (package split outcome, file location rule, seam name), section 1.3 (pinning verified), section 2.2 item 3 (miscompile not reproduced), section 4.4 (tooling and the gates now fixed), section 5 risks 1 and 3, section 6 (S0 shipped; S2 seam name; S3 file location and exemption), section 7 (questions 1, 2, 3, 4, 5, 6, 9, 10 resolved or re-scoped). `docs/61` section 6.5 points at the gates. No slice is added or removed; S3 gains two preconditions (the thread-per-connection limit of defect 3 is a known exemption, and the file stays under `_kernel/`), S5 inherits defect 2.
