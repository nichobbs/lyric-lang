# HTTP server benchmark (docs/73 slice S0)

The baseline that gates the replacement of the JVM `com.sun.net.httpserver` kernel and the Undertow
bindings by the shared pure-Lyric driver (`docs/73-jvm-pure-lyric-server-plan.md`, decision
`docs/decisions/D780-http-server-baseline-and-gates.md`). Not part of CI: `ci.yml` has no size headroom
(`scripts/ci/check-workflow-size.sh`) and the full run takes about an hour. Run it by hand or from a
nightly job. The recorded numbers are in `docs/progress/2026-11-24-http-server-baseline.md`.

## What is here

| File | Role |
|---|---|
| `server.l` | The server under test over `Std.HttpServer` (dotnet engine, JVM JDK-HttpServer kernel, native). Routes `GET /hello` ("ok") and `POST /echo`. A pool of `BENCH_WORKERS` (32) tasks pulls with `nextContext`. `BENCH_CERT`/`BENCH_KEY` make the listener TLS. |
| `server_web.l` | The same routes through `lyric-web`: Undertow on `--target jvm`, `Std.HttpServer` on dotnet and native. Built inside the lyric-web manifest. |
| `loadgen.l` | HTTP/1.1 load generator in Lyric over `Std.TcpHost` and `Std.Task` (runs on dotnet). Modes `keepalive`, `connclose`, `echo`, `idle`, `soak`. |
| `ws_server.l`, `ws_clients.l` | B7: a `lyric-ws` broadcast server and a client fleet that measures delivery latency (build inside the lyric-ws manifest). |
| `../../scripts/ci/http-server-benchmark.sh` | Driver: builds, starts the server, samples its RSS, threads and fds once a second, runs the scenarios, prints `target.scenario.key=value` lines. |
| `spikes/` | The throwaway docs/73 S0 spikes (a: package split, b: virtual-thread pinning). Not shipped; see its README. |

## Scenarios

| | Load | Figures |
|---|---|---|
| B1 | 64 keep-alive connections, `GET /hello`, 20 s after a 5 s warm-up | rps, p50/p99/max latency, server RSS, threads, fds |
| B2 | 64 workers, one connection per request (`Connection: close`) | rps, latency |
| B3 | 64 keep-alive connections, `POST /echo` with a 64 KiB body | rps, MiB/s, latency |
| B4 | `curl --http2 --parallel --parallel-max 32` over TLS, 20 000 requests | rps, latency, negotiated version (a server that does not negotiate h2 is reported, not measured) |
| B5 | 10 000 idle keep-alive connections held open while 8 connections trickle requests; then every idle connection is asked once more | server RSS, threads, fds, trickle p99, idle connections still alive |
| B6 | B1 at half its measured rate with a second generator doing connect/disconnect churn, 1800 s by default | RSS drift, last fd count, errors |
| B7 | `ws_server.l` + `ws_clients.l`: 1000 WebSocket clients, 1 KiB broadcast at 10 Hz | delivery latency p50/p99/max, messages seen per connection |
| b1w b2w b3w | B1, B2, B3 driven by `wrk -t4 -c64` instead of the Lyric generator (B3 posts a 64 KiB body through a Lua script) | rps, p50/p99, errors, server RSS |
| b4h | B4 driven by `h2load -n 200000 -c32 -m10 -t2` | rps, mean/max latency |

## Getting `wrk` and `h2load`

Neither is installed by default. Without root, from the Ubuntu archive (needs `archive.ubuntu.com`):

```sh
mkdir tools debs && cd debs
apt-get download wrk nghttp2-client libev4t64 libnghttp2-14 libcares2 libjansson4 libjemalloc2 libluajit-5.1-2 libluajit-5.1-common
for d in *.deb; do dpkg-deb -x "$d" ../tools; done
export PATH=$PWD/../tools/usr/bin:$PATH LD_LIBRARY_PATH=$PWD/../tools/usr/lib/x86_64-linux-gnu
```

On a hosted ubuntu runner `sudo apt-get install -y wrk nghttp2-client` is enough. The driver script uses them
when on `PATH`; without them run only `b1 b2 b3 b4 b5 b6` (the Lyric generator and `curl`).

## Running

```sh
make lyric                                              # ./bin/lyric
scripts/ci/http-server-benchmark.sh dotnet b1 b2 b3 b4 b5
scripts/ci/http-server-benchmark.sh jvm    b1 b2 b3 b5
scripts/ci/http-server-benchmark.sh undertow b1 b2 b3 b4 b5   # needs Maven Central for the restore
scripts/ci/http-server-benchmark.sh native b1 b2 b3 b5        # needs clang and lyric-rt
BENCH_SOAK_SECONDS=1800 scripts/ci/http-server-benchmark.sh dotnet b1 b6
scripts/ci/http-server-benchmark.sh dotnet b1w b2w b3w b4h     # with wrk and h2load on PATH
```

`jvm-nodelay` is the `jvm` target with `-Dsun.net.httpserver.nodelay=true`: the JDK server leaves Nagle on and, as
shipped, answers a keep-alive request in about 44 ms (docs/progress/2026-11-24-http-server-baseline.md).

B7 is run by hand: build `ws_server.l` inside the lyric-ws manifest (see its header; `--target dotnet`, or
`--target jvm --features jvm` for Undertow) and `ws_clients.l` for `--target jvm`, start the server with
`WS_PORT=8190 WS_SECONDS=75`, then `WS_PORT=8190 WS_CONNS=1000 WS_SECONDS=30 java -jar ws_clients.jar`. The dotnet
kernel needs `System.Threading.ThreadPool.MinThreads` raised in the server's `runtimeconfig.json` to accept 1000
connections (D780, defects).

Tunables are environment variables, listed in the script header (`BENCH_SECONDS`, `BENCH_CONNS`,
`BENCH_IDLE`, ...).

## Limits of the harness (read before comparing numbers)

- Server and load generator share the machine (4 cores in the recorded run). The Lyric generator reaches about
  half of `wrk`'s rate against the dotnet engine, so its own cost caps the offered load: use the `w`/`h`
  scenarios for any figure that gates a decision, and the Lyric rows as the fallback and cross-check.
- `curl --http2 --parallel` (B4) is a single threaded client: its figures are lower bounds. Use `b4h`.
- Single runs on a shared container: differences under about 10% are noise.
- The toolchain matters: a release's compiled dotnet stdlib bundle can predate a kernel change (v0.7.15 predates
  D621's `TCP_NODELAY` and shows a 43 ms h2 latency floor). Build the bundle from the tree under test.
- Latency is measured by the generator (write to last response byte), so it includes generator
  scheduling delay under load.
- The JVM/JDK-server and dotnet kernels are driven through the pull API with a fixed worker pool;
  Undertow through `Web.serve`, which has its own job dispatch. The comparison is of the stacks as an
  application meets them, not of the transports alone.
