# D793 - lyric-ws: a connection cap, a handshake timeout and an idle timeout tied to ping liveness (docs/73 slice S8, item ii)

**Status:** accepted. Extends D792 and D787.

## Context

`Ws.Kernel.Net` accepted every connection and bounded nothing: no cap (each connection holds two threads on dotnet), no handshake timeout (the documented `LYRIC_CONFIG_WS_SERVER_HANDSHAKETIMEOUTMS` was never read, so a peer that connected and sent nothing held a thread for good) and no idle timeout (a peer that vanished without a FIN, or that never answered pings, stayed registered until TCP gave up). The keepalive sent pings and checked nothing about the replies.

## Decision

1. **Cap.** `WsServerOptions.maxConnections`; `0` means the target's default from `Std.HttpServerHost.defaultMaxConnections()` (10 000 on the JVM, 1 000 on dotnet and native, D780 question 9), so the WebSocket server and the HTTP server follow one rule per target. A slot is taken at accept and released when the connection task ends, so connections still in their handshake count. The connection over the cap is answered `503 Service Unavailable` and closed (a `wss` listener closes it without an answer: its peer has not completed TLS). It is never registered, so `connectionCount` does not include it. The cap applies to `createEndpoint` endpoints too (the HTTP server in front has its own cap as well).
2. **Handshake timeout.** `WsServerOptions.handshakeTimeoutMs` (default 10 000, `0` = off) sets `hostSetIoTimeout` for the TLS handshake (`hostUpgradeServerTlsPrepared`'s parameter) and the HTTP upgrade read, and is cleared to `0` once the upgrade completes. It is the first implementation of the `HANDSHAKETIMEOUTMS` the module header documents, as an option rather than an environment variable.
3. **Idle timeout tied to ping liveness.** `WsServerOptions.idleTimeoutMs` (default 90 000, three default ping intervals, `0` = off). Every successful read updates `lastRxNs`; the maintenance task starts the close handshake (Close 1001 "idle timeout") when nothing has been received for that long. A Pong is a received frame, so a client that answers the keepalive Ping is never idle however quiet its application is, and one that does not is closed after about the timeout; the close is shut down 5 s later if unanswered, and `onClose` then reports 1001 rather than 1006. The ping interval is still read from `LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS` (D787); a deployment that sets it to `0` should set `idleTimeoutMs` to `0` as well, or quiet clients are closed after 90 s.
4. **The ping loop became the maintenance task.** It always runs (one task per connection, as before when pings were on), wakes every quarter of the shortest of the ping interval, the idle timeout and the write timeout (10 ms to 1 s), and does the write watchdog (D792), the close timeout, the idle check and the ping. It skips a ping while data is queued: the write watchdog covers that case.

## Verification

`tests/ws_hardening_tests.l`: the cap (two admitted, the third answered 503 and not counted, a freed slot reused); the handshake timeout (a silent peer is closed in under 4 s with a 500 ms timeout, on plain and TLS listeners); the idle timeout (a silent client receives Close 1001, `onClose` reports 1001); liveness (with a 200 ms ping and an 800 ms idle timeout, a client that pongs stays connected for 3 s and received at least 5 pings, a silent one is closed). dotnet, JVM and native all pass. No failure-injection of the cap's 1 000 default was run on dotnet and native (the tests use explicit caps).
