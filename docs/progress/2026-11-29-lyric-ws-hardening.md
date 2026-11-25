# lyric-ws hardening on every target: bounded outbound path, limits, wss (docs/73 slice S8)

Slice S8 of `docs/73-jvm-pure-lyric-server-plan.md`. Decisions: D792 (outbound queue and write timeout), D793 (cap, handshake and idle timeouts), D794 (`startServerTls`), D795 (Autobahn and permessage-deflate). Each section below is verifiable on its own.

## What shipped

### (i) Bounded outbound path and write timeout (D792)

- `Ws.Kernel.Net` queues every outbound frame per connection and writes it from one drain task; `send` and `broadcast` return once the frame is queued. A connection whose backlog passes `WsServerOptions.maxOutboundBytes` (1 MiB), or whose write makes no progress for `writeTimeoutMs` (10 s), is dropped: `send` returns `Err("slow consumer ...")`, `onError` is told, `onClose` reports 1008, the socket is shut down. `broadcast` encodes once and never writes to a socket.
- Acceptance: B7 and a failure-injection test with a client that stops reading, on dotnet, the JVM and native (`tests/ws_hardening_tests.l`: `a client that stops reading is dropped ...`, `write timeout: ...`, `a send to a connection already dropped ...`). Removing the backlog bound and the write watchdog makes those three fail (mutation run on dotnet).
- Slow-consumer numbers (50 readers plus 2 clients that never read, 60 000-byte frames at 10 Hz, 30 s): before, readers got 66 to 67 of 299 broadcasts and one `broadcastText` call took 23.4 s (dotnet and JVM alike); after, every reader got 299 of 299 (298 on the JVM run), worst call 5 ms (18 ms on the JVM). Plain B7 (1000 clients, 1 KiB at 10 Hz): dotnet p99 52 ms before and 16 ms after, p50 8 and 7; JVM p99 33 to 36 before and 15 to 20 after. Tables in D792.

### (ii) Cap, handshake timeout, idle timeout (D793)

- `maxConnections` (per-target default from `Std.HttpServerHost.defaultMaxConnections`), `handshakeTimeoutMs` (10 s; the documented `HANDSHAKETIMEOUTMS` had never been read) and `idleTimeoutMs` (90 s, reset by any received byte, a Pong included). The ping loop is now a maintenance task that also runs the write watchdog and the idle check.
- Tests: `connection cap ...`, `handshake timeout ...`, `idle timeout ...`, `idle timeout is tied to ping liveness ...`.

### (iii) wss (D794)

- `Ws.startServerTls(host, port, path, tls, options, handler)`; configuration validated before the bind, per-connection handshake on its own task, prepared TLS state released at `stopServer`.
- Tests: `wss: ...` (six: TLS terminates and answers, untrusted CA fails, mutual TLS refuses and admits, bad configuration refused, silent peer cut off, and a full WebSocket echo over TLS on native only).

### (iv) Autobahn (D795): not done, blockers recorded

No Docker daemon in the container, so no job script or expected-results file is checked in; D795 lists what the nightly needs.

### (v) permessage-deflate (D795): out of scope, decided

## Files

`lyric-ws/src/_kernel/net/ws_kernel.l` (outbound queue, drain, maintenance task, limits, TLS, cap), `lyric-ws/src/ws.l` (`WsServerOptions` fields, `kernelLimits`, `startServerTls`, `startOn`, two kernel wrappers), `lyric-ws/tests/ws_hardening_tests.l` and its line in `lyric-ws/lyric.toml`, `scripts/ci/native-web-smoke.sh` (the new suite on native), `benchmarks/http_server/ws_server.l` and `ws_clients.l` (`WS_STALLED`, `worst_call_ms`), `lyric-ws/README.md`, `docs/62`, `docs/73`, `CLAUDE.md`, book chapter 29.

## How it was verified

`make lyric` cannot finish in this container (AOT needs .NET 11). The toolchain was the v0.7.15 release compiler with the stdlib bundle rebuilt from the tree (the stdlib is unchanged by this slice) and `LYRIC_STD_PATH` at the tree.

| suite | dotnet | JVM (`--no-default-features --features jvm`) | native |
|---|---|---|---|
| `Ws.WsTests` | 6 | 6 | 6 |
| `Ws.WsFrameTests` | 28 | 28 | 28 |
| `Ws.WsHandshakeTests` | 18 | 18 | 18 |
| `Ws.WsE2eTests` | 11 | 11 | 11 |
| `Ws.WsSecurityAspectWeavingTests` | 6 | 6 | does not build (A0045, #3498, before and after) |
| `Ws.WsHardeningTests` (new) | 12 | 12 | 13 |

`lyric-web` on dotnet: 10 suites pass; `Web.WebSocketTests` (4) passes on the JVM through `Std.HttpServer.takeConnection` and the new queue. `scripts/audit-axioms.sh`, `scripts/audit-kernel-stubs.sh`, `scripts/ci/check-workflow-size.sh` (490 692 of 500 000 bytes, ci.yml untouched) and `scripts/ci/check-library-stability.sh` pass. `lyric fmt --write` is v0.7.15's, not the tree's.

## Not verified, and findings for later

- Autobahn was not run (no Docker). The CI scripts were edited but not run end to end.
- Native B7 numbers were not taken (the client fleet is JVM-only); native is covered by the 13 hardening tests.
- Under 1000 simultaneous dials the JVM client fleet loses 0 to 7 connections with the old and the new server alike (listen backlog 128 in the JVM `Std.TcpHost`); not a regression, not investigated.
- The drain task is a `runBackground` per burst. On native that is a pthread per burst; at a sustained high frame rate a persistent writer with a condition variable would cost less. Native has no condition-variable primitive in `ws_prims.l`; left until it is measured to matter.
- The kernel does not answer a client Ping; see D795.

## Issue texts for what was found and not fixed

1. **lyric-ws: add the Autobahn nightly (docs/73 S8 iv).** Needs a runner with Docker and the `crossbario/autobahn-testsuite` image; a Lyric echo server (`startServerWithOptions`, `maxMessageSizeBytes = 16777216`, `idleTimeoutMs = 0`, `maxOutboundBytes` at least 16 MiB); `scripts/ci/autobahn-ws.sh` and one workflow step; an expected-results file generated from a first real run and reviewed per case (cases 12.* and 13.* `UNIMPLEMENTED` until permessage-deflate). Prerequisite fix: answer a client Ping with a Pong carrying its payload in `runReadLoop` (RFC 6455 section 5.5.2); keep delivering `Ping` to `onMessage`, update `ws_e2e_tests.l`'s ping test and the kernel header.
2. **lyric-ws: permessage-deflate (RFC 7692).** Blocked on a streaming raw DEFLATE with context takeover and `no_context_takeover` in `Std.Zip` (today only one-shot `deflate`/`inflate`); then negotiation in `Ws.Handshake`, RSV1 in `Ws.Frame`, and the Autobahn 12.*/13.* cases.
3. **Std.TcpHost: client TLS connect on dotnet and the JVM** (`hostConnectTls`, `hostUpgradeClientTls` and `TlsClientTrust` exist on native only). Lets `lyric-ws` test WebSocket frames over TLS on every target (D794) and removes a native-only seam from raw TLS clients.
4. **lyric-ws: a persistent writer per connection** (native has no condition variable in `Ws.Kernel.Net`'s prims; the drain-task-per-burst design pays one thread start per burst there).
5. **JVM `Std.TcpHost` listen backlog of 128** drops connects under 1000 simultaneous dials (B7 client fleet: up to 7 of 1000 failed with the old server too).
