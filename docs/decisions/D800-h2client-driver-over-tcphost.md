# D800 - `Std.HttpEngine.H2Client`: a pure-Lyric HTTP/2 client driver over `Std.TcpHost`, and the concurrency contract it is written against (docs/72 slice 5, OQ-7)

**Status:** accepted. Implements slice 5 of `docs/72-h2-client-role-plan.md` (§3.5 to §3.7; resolves OQ-7). Builds on D797 (the `H2Conn` client role), D799 (client TLS with ALPN, `hostReadDeadline`) and D786 (`Std.HttpServerHost`, the concurrency seam). Pooling, queueing past `MAX_CONCURRENT_STREAMS`, idle policy and transparent retry are slice 6.

## OQ-7: the concurrency contract

The driver uses exactly the primitives of `Std.HttpServerHost`, which the shared tests pin on dotnet, the JVM and native: `startTask` (a real thread on every target; `spawn` is synchronous on MSIL and is not used), the reentrant `Mutex`, the counting `Semaphore` (a post before a wait is not lost) and `runGuarded`. `Std.Task` and `protected type` were not chosen: the server driver already runs on this seam on all three targets, and a second primitive set would need its own parity proof. The spike is the test suite itself, which exercises a reader task, concurrent callers, cross-thread cancel and close on dotnet, the JVM and native (see the progress note for the counts).

There is no condition variable and no timed wait in the seam, and the driver does not need them:

- **One lock per connection** covers the FSM, the call table, every call's queue and every socket write (coarse, as D287 chose; `H2Connection` is one mutable value and ids and HPACK state must reach the wire in allocation order). A write holds it, so a stalled peer is bounded by the transport I/O timeout (`writeTimeoutMs`): a timed-out write tears the connection down instead of freezing every call.
- **A mailbox per call**: a queue under the connection lock plus a semaphore posted once per queued event. The consumer checks the queue first and only then waits, so a stale credit costs one extra loop, never a lost event. A second per-call semaphore wakes a sender blocked on flow control. Every call gets exactly one terminal event.
- **Deadlines, keepalive and drain are the reader's job.** The reader blocks in `hostReadDeadline` for at most `pollIntervalMs` (default 50 ms) and on every wake expires calls past their deadline (RST_STREAM CANCEL, terminal `H2FailDeadlineExceeded`), sends or checks keepalive PINGs and closes a drained connection. Resolution is one poll interval. No timer thread, no timed semaphore wait.
- **Close interrupts a blocked read on every target** by `hostShutdown` from the closing thread, not by the poll: the test sets a 60 s poll interval and `h2Close` still returns in milliseconds on dotnet, the JVM and native. The reader owns `hostClose`, so the socket is released exactly once.

## Decision

1. **Module** `Std.HttpEngine.H2Client` (`lyric-stdlib/std/http_h2client.l`), no extern, listed in `lyric.full.toml` and `STABILITY.md`. Names are `h2`-prefixed (`h2Connect`, `h2StartCall`, `h2SendBody`, `h2NextEvent`, `h2Cancel`, `h2Close`), the union cases `H2Fail*`, `H2Call*`, `H2Start*`, `H2Body*`, `H2Connect*` (the dial errors, type `H2DialError`), because `H2ConnectError` is already an `H2ErrorCode` case in `Std.HttpEngine.H2Frame` and the bundle resolves names across packages.
2. **Connect**: `H2Plain(host, port)` is h2c with prior knowledge; `H2Secure(host, port, trust, identity, minVersion)` is TLS offering only `h2` (`hostConnect`, `hostSetIoTimeout(handshakeTimeoutMs)`, `hostUpgradeClientTls`). A server that selects anything else is `H2ConnectAlpnNotH2`: no silent downgrade. The client preface and a connection-window `WINDOW_UPDATE` (to `connectionWindow`, default 16 MiB) are the first write.
3. **Call lifecycle**: `h2StartCall(conn, headers, endStream, deadlineMs)`, `h2SendBody(call, bytes, endStream)`, `h2NextEvent(call)` (`H2CallInformational`, `H2CallHeaders`, `H2CallData`, `H2CallTrailers`, then `H2CallEnded` or `H2CallFailed`), `h2Cancel`. `h2SendBody` frames within the peer's maximum frame size and both windows and blocks on an empty window until a WINDOW_UPDATE, a SETTINGS change or a terminal event.
4. **Flow control**: the connection receive window is credited when bytes arrive (one slow call cannot starve its neighbours), a stream window only as the consumer takes data out of the mailbox, in batches of half a window, so a consumer that stops reading stalls the peer at `streamWindow` bytes (tested: the peer observes the window stay shut, then the body completes intact once reading resumes).
5. **Failure model** (`H2CallFailure`): `H2FailDeadlineExceeded`, `H2FailCancelled`, `H2FailReset(code)`, `H2FailRefused` (REFUSED_STREAM), `H2FailUnprocessed` (above a GOAWAY's last-stream-id), `H2FailConnectionLost`, `H2FailProtocol`. `h2FailureIsRetrySafe` is true for exactly `H2FailRefused` and `H2FailUnprocessed` (RFC 9113 8.7). Data already received when a connection is lost is delivered before the failure.
6. **GOAWAY**: the connection becomes draining, `h2StartCall` returns `H2StartDraining`, streams above the last-stream-id fail unprocessed, streams at or below it finish, and a drained connection closes itself.
7. **Keepalive PING** only when configured (`keepAliveIntervalMs`, default 0, OQ-5): sent after that long without receiving anything while calls are active (or always with `keepAliveWithoutCalls`), the connection fails if the ack is not back within `keepAliveTimeoutMs`.
8. **Stream limit**: `h2StartCall` returns `H2StartStreamLimit(active, limit)` when the peer's `SETTINGS_MAX_CONCURRENT_STREAMS` is reached. Queueing for a free slot is slice 6 (pooling).
9. **Tests**: `http_h2client_tests.l` (23 tests: a scripted h2c peer built from the `H2Conn` server role, and the real `Std.HttpServer` over TLS with ALPN) and `http_h2client_interop_tests.l` (6 tests against `nghttpd`, h2c and TLS+ALPN, started by `scripts/ci/h2conn-tests.sh`, which `ci.yml` already runs per target, so the workflow file does not grow).

## Findings recorded

- `Std.HttpServer` serves h2 over TLS only (D128 decision 7), so "the client against the pure-Lyric server over h2c" is exercised against the `H2Conn` server role over `Std.TcpHost` (the same FSM the shared driver runs), and the TLS path against the real `Std.HttpServer`.
- The driver polls with `hostReadDeadline` for its whole life, so every call on a TLS connection (the `Std.HttpServer` tests) also exercises slice 4's guarantee that a passed deadline leaves the connection intact.
- A `match` arm whose body is a bare assignment (`case P -> x = y`) does not parse in a test file and mis-resolves in a module; the driver wraps every such arm in braces. Repro and issue are in the hand-back.

## Not changed

No `Std.Http` behaviour, no server code, no kernel. `lyric-grpc` is untouched (slice 6).
