# Plan: replace the JVM Undertow and JDK-HttpServer stacks with the pure-Lyric engine over `Std.TcpHost`

Status: research and design; slice S1 shipped (D621), the rest is not started. Everything below marked (V) was verified by reading the repository on 2026-11-17. Items marked (A) are assumptions or measurements still to be taken, and S0 below exists to settle them.

## 0. Summary and corrections to the brief

Recommendation: do it, in the order S0, S1, S2, S3, S4 for the server and S6, S7 for lyric-web and lyric-ws, after a baseline benchmark. Delete the JDK `com.sun.net.httpserver` kernel and both Undertow bindings. Do not keep any of them as a fallback.

Corrections to the premises (all V):

1. **There is no shared connection driver today.** `Std.HttpEngine`, `H2Conn`, `H2Frame` and `Hpack` are shared Lyric. The accept loop, per-connection driver, h2 send scheduler, limits and stop logic are written once per kernel: `lyric-stdlib/std/_kernel/http_server.l` (2456 lines, dotnet) and `lyric-stdlib/std/_kernel_native/http_server.l` (2018 lines, native). There is no `std/http_server.l`; the package `Std.HttpServer` is the kernel file itself. Sharing the driver is new work.
2. **Native does not serve h2.** Its header says "v1 is HTTP/1.1 only, no h2". A connection whose ALPN is `h2` is closed (line 1127). h2 on native is N9.5, #6106. Native also lacks `startListenerWithLimits`, `startListenerTlsWithLimits` and the `resolve*` helpers other than the three listed below (its limits are always `EngineLimits.defaults()`). dotnet is the only target with h2 on the engine.
3. **The stop-race fixes (#6791 #6792 #6795 #6797 #6798 #6802 #6803 #6806, and #6796) exist only in the native kernel.** The dotnet `stopListener` only calls `hostStopListener`; it does not wait for or close in-flight connections. Most of these are native memory-lifetime bugs (malloc'd mutex/semaphore, pthread closure lifetime, fd reuse) that cannot occur on the JVM. The logical ones (idle keep-alive hanging stop, queued-but-unanswered contexts, accept wake-up) apply to the JVM and must be re-tested there. See section 1.6.
4. **The JVM `Std.TcpHost` kernel (D611) is a first version, not yet fit to carry a server** (V from reading `_kernel_jvm/tcp_host.l`): `hostRead` allocates a `ByteArrayOutputStream` per call and does `read()`, `available()`, `readNBytes()` on an unbuffered stream. With an I/O timeout set (the server always sets one) every `hostWrite` starts a virtual thread and joins it. There is no `hostShutdown`. And it `import`s `Std.HttpServer` for `serverSslContextFromConfig[Mtls]`, so the new `Std.HttpServer` cannot import `Std.TcpHost` without a cycle. S1 fixes these.
5. **D605 is "Std.Http on native runs a send within its cancellation token's limits"**, the native HTTP client. The native bounded transport ops (`hostReadBounded`, `hostWriteBounded`, `hostConnectBounded`, wake pipe) live in `_kernel_native/tcp_host.l`. D611 is the JVM `Std.TcpHost` kernel plus `hostConnect(..., connectTimeoutMs)`. D612 is `HttpError.Timeout`. Next free decision id is D614 (D613 exists).
6. **`lyric-ws` pure-Lyric (dotnet/native) has no TLS listener, no write timeout, no connection cap, no permessage-deflate, and a serial broadcast that blocks behind a slow consumer** (V, section 3). The JVM Undertow ws kernel is weaker still (no fragment reassembly, no ping keepalive, lenient UTF-8, per its own header). So the port is a net functional gain on the JVM, and the pure-Lyric gaps need closing on all targets in the same effort.
7. **Undertow is also a compiler test fixture.** `lyric-compiler/lyric/jvm_auto_ffi_bridge_self_test.l` (lines 43, 179, 596-605), `lyric-compiler/lyric/cli_build_self_test.l:1081`, `scripts/ci/cli-args-e2e.sh:186`, `scripts/ci/manifest-jvm-maven-test.sh`, `scripts/ci/ui-jvm-suites.sh` and `scripts/ci/jvm-ecosystem-suites.sh` use the `io.undertow:undertow-core` coordinate or the restored Undertow classpath as the real-world Maven case. Dropping the dependency requires retargeting these (section 6).
8. `.github/workflows/ci.yml` is 499489 bytes against a 500000 ceiling: 511 bytes of headroom. Every new CI check must be a script under `scripts/ci/` invoked by a one-line step, and the Undertow smoke steps (lines ~6534 and ~6559) should be repointed or removed in place, which frees bytes.
9. Verified good news: `http_engine_tests.l` and `http_h2conn_tests.l` already run on `--target jvm` in CI (ci.yml lines ~4781 and ~4814), so the engine and the h2 FSM are known to compile and pass on the JVM backend. Only the driver (ref records, `inout`, closures into threads) is unproven there.

## 1. Std.HttpServer on the JVM

### 1.1 Public surface (V, from `pub` declarations in each kernel)

| Item | dotnet | native | JVM today |
|---|---|---|---|
| `startListener(prefix)` | yes | yes | yes (plaintext only; `https://` rejected) |
| `startListenerWithLimits(prefix, limits)` | yes | no | no |
| `startListenerTls(host, port, tls)` | yes | yes | yes (no mTLS error case) |
| `startListenerTlsWithLimits(...)` | yes | no | no |
| `nextContext`, `stopListener` | yes | yes | yes |
| `requestMethod/Path/Query/Body/BodyBytes/Headers`, `urlDecode` | yes | yes | yes |
| `respondText`, `respondJson`, `respondBytesWithHeaders` | yes | yes | yes |
| `beginChunkedResponse`, `streamWriteChunk`, `endChunkedResponse`, `HttpChunkedStream` | yes | yes | yes |
| `takeConnection` | yes | yes | no ("permanent difference") |
| `TlsListenError` (+ `.message`) | `NotSupportedOnTarget`, `InvalidConfig`; has `.message` | same | `NotSupportedOnTarget` only; no `.message` |
| `resolveMaxConcurrentConnections`, `resolveTlsHandshakeTimeoutMs`, `resolveConnectionIdleTimeoutMs` | yes | yes | no |
| `h2RejectedStreamRetentionWindow`, `h2RejectedStreamIsReclaimable` | yes | no | no |
| `HttpContext`, `HttpListener`, `ConnHandoff`, `H2Link`, `H2Notice`, `H2Chunk` records | yes (records) | records | `HttpContext` is an extern alias of `HttpExchange` |
| `serverSslContextFromConfig`, `serverSslContextFromConfigMtls` | no | no | pub, used by `_kernel_jvm/tcp_host.l` and lyric-web |

The JVM kernel has the 12 base functions plus `requestBodyBytes`, `startListenerTls`, the three chunked helpers and the two SSL-context helpers. After this work the JVM must export exactly the dotnet surface. Target surface for all three: the dotnet list above. Native and JVM gain the `WithLimits` variants, `TlsListenError.InvalidConfig`/`.message` and the `resolve*` helpers; `h2RejectedStream*` are test seams that come along with the shared driver. `serverSslContextFromConfig[Mtls]` move into `_kernel_jvm/tcp_host.l` (or `_kernel_jvm/tls_host.l`) as internal helpers; lyric-web stops calling them once its JVM kernel is deleted. `HttpContext` becomes the shared Lyric record on the JVM, as on dotnet, which is source compatible for consumers that bind by inference (lyric-web does, V by the dotnet precedent in the header of `_kernel/http_server.l`).

### 1.2 Architecture: one shared driver, per-target seam

Design: move everything that is not a primitive into a new shared file `lyric-stdlib/std/http_server.l` (package `Std.HttpServer`, same public surface). Put the primitives in a new kernel package `Std.HttpServerHost` with three twins: `_kernel/http_server_host.l`, `_kernel_jvm/http_server_host.l`, `_kernel_native/http_server_host.l`. This is the established `Std.Http` + `Std.HttpHost` and `Std.Tls` + `Std.TlsHost` pattern.

Why not a same-package multi-file split: the JVM kernel header records that a package spanning a top-level file plus a `_kernel_jvm/`-only file broke static-call resolution (#5932, D-progress-889, first-wins `Jvm.Bridge`). Two packages avoid it. S0 must confirm this still holds and that the per-package stdlib DLL/JAR build handles it.

Minimum per-target seam (`Std.HttpServerHost`), about 12 functions:

- `spawn(work: () -> Unit): Unit`, fire-and-forget thread. dotnet `Task.Run` (plus `ensureServerThreadCapacity`), JVM `Thread.startVirtualThread` over a `Runnable` record (precedent: `_kernel_jvm/task.l` `scopeSpawn`, `_kernel_jvm/tcp_host.l` write watchdog, lyric-web `WorkerLoopRunnable`), native `pthread_create` with the closure-retain discipline of #6797.
- `Mutex`: `newMutex`, `lock`, `unlock`, `release`. dotnet `Monitor`, JVM `ReentrantLock` (not `synchronized`, which pins carrier threads on JDK 21; `_kernel_jvm/task.l` already uses `ReentrantLock`), native `lyric_mutex_*`.
- `Semaphore` (counting): `newSem(n)`, `semWait`, `semTryWait`, `semPost`, `release`. dotnet `SemaphoreSlim`, JVM `java.util.concurrent.Semaphore`, native `lyric_sem_*`. A timed wait is needed for the h2 drain watchdog; either add `semWaitMs` or keep the dotnet 100 ms slice polling (`h2DrainWatchSliceMs`).
- `runGuarded(work, onFailure)`: `try/catch Bug` on dotnet and JVM, a direct call on native (no unwinding, D-N-003). This mirrors lyric-web's `runJobGuarded` prims.
- `joinAll`/thread handles for native shutdown (native only needs a real join; dotnet/JVM can no-op). Model as an opaque `WorkerSet` owned by the listener: `workerAdd`, `workerJoinAll`.

Everything else becomes shared Lyric built on those: the FIFO of ready contexts is a `List[HttpContext]` under a mutex plus a counting semaphore, exactly the native design (`ServerQueue`, V). The dotnet `ConcurrentQueue`+`SemaphoreSlim` collapses into the same shape. Rules for the shared file, because it must compile on all three backends:

- No `try/catch` (use `runGuarded`), no `inout` parameters (native `#6794`: return the advanced `Connection` in a `ReadOutcome` record as native does; the dotnet `readOneRequest(conn, inout engineConn)` is not portable), no `NativePtr`/`Long`-as-pointer fields (hidden inside `HttpServerHost` records), no `String[i]` indexing (native #6237; use `.indexOf/.substring` or `Std.Char`/`Std.EncodingHost` helpers).
- Ref records with `var` fields (dotnet `H2Link`, `ConnHandoff`, `H2ConnState`): assumed supported on native and JVM (A). S0 compiles a reduced driver on all three to prove it. The generic-extern-in-closure degradation noted in the dotnet header (#2494: `Option[TlsServerConfig]` threaded through a closure) is why that file has separate plain and TLS accept loops; keep that split.
- Closure invoked from a closure: dotnet T0123 (`web_prims.l` comment, V) means call interface methods, not captured closure values, inside the spawned body. Define a `Job` interface or record-with-method for the seam instead of passing raw closures where the dotnet backend needs it. `Std.HttpServerHost.spawn` taking `() -> Unit` is what the dotnet kernel already uses (`taskRun({ -> ... })` in `_kernel/http_server.l`), so a closure parameter is fine at the seam; only a captured closure value called from inside another closure is the problem.

Migration order inside the shared extraction, to bound risk: the dotnet kernel is the most complete (h1, h2 scheduler, limits, handshake and idle timeouts, takeConnection) and has the largest test suite (33 tests, `http_server_dotnet_tests.l`). Extract it first and keep dotnet green with no behaviour change (S3). Then the JVM adopts (S4). Native adopts last (S5), which also delivers h2, `WithLimits` and the full surface on native, closing #6106.

### 1.3 JVM threading model (V for precedents, A for performance)

- One virtual thread per accepted connection, via `Thread.startVirtualThread`. The JVM kernels already use virtual threads for background work: `_kernel_jvm/task.l` `scopeSpawn`, the `tcp_host.l` write watchdog, lyric-web `startWorkerLoop` (`Executors.newVirtualThreadPerTaskExecutor`). Platform threads would cap idle keep-alive connections far below what a virtual thread allows; Undertow's XNIO model scales idle connections cheaply, so virtual threads are the way to match it.
- h2: two threads per connection (reader task and connection task), as on dotnet. Handlers never touch the wire; they enqueue to the stream outbox and signal `wake`. The send scheduler (one frame per in-flight stream per pass, flow-control bounded, #6107) is portable Lyric once the seam exists.
- Blocking socket I/O on virtual threads is parked, not pinned, for `Socket`/`ServerSocket`. JSSE `SSLSocket` uses `ReentrantLock` internally on JDK 21 (A, believed true since JDK 19; verify in S0 with a pinning check, `-Djdk.tracePinnedThreads=full`).
- JDK baseline: virtual threads need JDK 21, which the repo already assumes for JVM (docs/44, V).
- Pull-model bridge: the shared accept loop enqueues a ready `HttpContext` into the mutex+semaphore FIFO; `nextContext` does `semWait` then a locked pop; the connection thread blocks on the context's `done` semaphore until a `respond*`/`takeConnection` call signals it (identical to dotnet and native today). The cost on the JVM is one extra thread hop per request versus Undertow's direct handler, since lyric-web pulls on one thread and spawns a job per request (`spawnRequestJob`). Measure in S0; if material, add an optional push entry point (`serveHandler(listener, handler)`) that dispatches on the connection thread. That is an additive API decision, listed as an open question, not part of the first slice.

### 1.4 Behaviours to carry over, with the file that owns the reference implementation

All of these live in dotnet `_kernel/http_server.l` today and move into the shared driver:

- Accept loop and permit: `onAccepted`/`plainAcceptLoop`/`tlsAcceptLoop` (lines ~899-1035). The accept loop takes a connection permit (`connLimit` semaphore, `LYRIC_HTTP_MAX_CONNECTIONS`, default 1000, #6071) before spawning, so excess connections queue in the OS backlog. JVM needs `hostListen` to set a sensible backlog (check: `ServerSocket` default is 50; add a backlog parameter or constant in S1, A).
- Per-connection driver and keep-alive: `processConnection`. A `defer` closes the socket unless `handoff.taken`, and always releases the permit (#6221). Keep-alive is the engine's decision (`shouldClose`).
- Request-body admission (#7269): the engine buffers the body up to `EngineLimits.maxBodyBytes` (default 10 MiB) and answers `413` via `ProtocolError`; the JVM's current ad hoc `readBoundedBody` goes away. Header and request-line limits come free from the engine corpus (`http_engine_tests.l`, 74 tests).
- Timeouts (#7268): TLS handshake runs on the connection's thread under `LYRIC_HTTPS_HANDSHAKE_TIMEOUT_MS` (default 10 s); post-handshake every read and write is bounded by `LYRIC_HTTP_IDLE_TIMEOUT_MS` (default 120 s) through `hostSetIoTimeout`. JVM `hostUpgradeServerTlsPrepared` already takes the handshake timeout (V, sets `SO_TIMEOUT` around `startHandshake`). Note the JVM idle timeout is a read `SO_TIMEOUT`; the write path was a per-write virtual thread watchdog, replaced in S1 (D621) by one shared watchdog.
- 100-continue, error responses before dispatch (`writeErrorResponse`), pipelining flag `trailingInput`, `Connection` header policy (`appendConnectionHeader`), header injection guard (`responseHeaderSafe`), reason phrases.
- h2: ALPN select, h2 request line extraction, per-stream body cap with terminal `rejectedStreams` bookkeeping (#6144/#6145/#6566), inbound credit, stream chunk credit (backpressure), drain watchdog, RST_STREAM on HPACK failure. All pure Lyric over `H2Conn`.
- `takeConnection`: refuses h2, HTTP/1.0 and pipelined input, sets `handoff.taken`, signals `done`, returns the live `Conn` which the new owner must close. On the JVM the returned `Conn` is the plain or `SSLSocket`-wrapped socket from `Std.TcpHost`, so the WebSocket kernel works on it unchanged.

### 1.5 TLS, ALPN and h2 on the JVM

- Plain and TLS accept: `hostAccept` then `hostUpgradeServerTlsPrepared`. ALPN offers `h2` then `http/1.1` (D611, V). `hostAlpn` selects the protocol on each connection, exactly as dotnet does at `onAccepted`.
- mTLS: `requireClientCert` is `setNeedClientAuth`; `clientCa` alone is `setWantClientAuth` (D611, V). The misconfiguration guard (`requireClientCert` without `clientCa` returns `InvalidConfig`) moves into the shared `startListenerTlsWithLimits`, as on dotnet.
- TLS 1.2 floor and `minVersion = Tls13`: the construction in `_kernel_jvm/http_server.l` (`buildServerSslContextCore`, `assertProtocolFloor`, reflective `KeyManager[]`/`Certificate[]` bridging, ~250 lines) moves into `_kernel_jvm/tcp_host.l` (it already calls `buildContext`, V line 264, which delegates to `HttpSrv.serverSslContextFromConfig`). This removes the `Std.TcpHost` to `Std.HttpServer` cycle. Keep the reflection bridge (the rationale in that header, #5930/#5931, concerns JVM auto-FFI limits that still apply (A)).
- Test pinning for h2 on the JVM: the dotnet suite cases for GET/POST/multiplex/over-cap/large body/interleave/chunked backpressure (`http_server_dotnet_tests.l` lines 668-1316) become target-neutral; plus a `curl --http2` smoke modelled on `scripts/ci/dotnet-h2-smoke.sh` (V). Keep the existing JVM in-process check pattern (JDK `HttpClient` negotiating h2 via `Std.Http` `negotiatedVersion() == Http2`) as the second independent client.

### 1.6 Graceful stop: what must be re-proven on the JVM

dotnet's `stopListener` only stops accepting. Native's is the strongest (blocks until all connection threads exit). The JVM needs a defined contract; recommended: `stopListener` (a) sets a `stopping` flag under the queue mutex, (b) `hostStopListener` closes the server socket (D611: wakes `accept` with `AcceptFailed`), (c) closes every registered active connection (`hostShutdown`, see below), (d) drains queued-unanswered contexts by posting their `done` semaphores, (e) joins the accept thread and, via the `WorkerSet`, all connection threads on native only. It does not wait for contexts already handed to a caller by `nextContext`; this is an existing caller obligation on every target and stays documented (native header, "What this does NOT fix").

Regression map. Each row names the race, whether it can occur on the JVM, and the required test (port `llvm_http_server_self_test.l` items E-J to a target-neutral stdlib test where possible):

| Issue | Race | JVM relevance | Required test on JVM |
|---|---|---|---|
| #6791 | stop hangs on an idle keep-alive connection (handler parked in `hostRead`) | Real. `Socket.close()` from another thread unblocks a virtual thread parked in socket read, but only if the connection is registered | Connect, one request, keep alive, `stopListener` must return and the client must see EOF |
| #6792 | connection registered after its thread spawns, so a fast-finishing connection leaves a stale entry | Real as a logic bug (stale entry later closes a different socket only on native fd reuse; on the JVM it leaks an entry). Register before spawn | 200 connect-and-drop cycles, then one real request, then `stop` |
| #6795 | `hostShutdown` loop released the mutex between snapshot and shutdown | Idempotent `close()` makes it benign on the JVM, but registry removal vs iteration is still a data race | 20 concurrent `Connection: close` clients, stop mid-flight |
| #6796/#6798 | drain consumed the wrong number of semaphore credits; request parsed after the drain parks forever | Real: the `stopping` flag under the mutex plus `done` post is required | Never-pulled queued requests at stop; request completing parse after stop |
| #6797 | pthread closure freed before thread reads it | Native only | n/a (stays in native tests) |
| #6799 | bind-failure path leaks mutex/sem | Native only | n/a |
| #6802 | `stopListener` destroys mutex/sem while a puller is parked in `nextContext` | Native memory hazard; on the JVM the equivalent is a puller that never wakes. Recommended: `nextContext` returns/panics deterministically after stop (decision needed, section 7) | 15 iterations of puller racing `stop` |
| #6803 | enqueue released the mutex before posting the semaphore, so the drain missed an item | Real as logic. Post the semaphore while holding the mutex, or drain by list length | 20 requests queued, none pulled, `stop` |
| #6806 | accept not woken on a never-connected listener | `ServerSocket.close()` wakes `accept` portably (D611) | start then stop immediately, 10 iterations |
| #7268 | TLS handshake on the accept loop blocked later clients | Same fix: handshake on connection thread | silent TCP peer plus real TLS client concurrently |

This needs `hostShutdown(conn)` on dotnet and the JVM (native has it, V line 1010). JVM: `Socket.shutdownInput()`/`shutdownOutput()`, or `close()`; for an `SSLSocket` `close()` is the reliable choice. dotnet: `Socket.Shutdown(Both)` through the `NetworkStream`. Add as an additive `Std.TcpHost` function in S1.

## 2. lyric-web

### 2.1 What is JVM-specific today (V, 542-line `_kernel/jvm/web_kernel.l`, 22 extern types)

- `serve` and `serveTls` (Undertow builder, `LyricUndertowHandler`, request reading with the 10 MiB cap, response writing, HTTP/2 via `ENABLE_HTTP2`): replaced entirely.
- `startWorkerLoop` (virtual-thread executor): becomes a JVM `web_prims` twin using the same background-run seam.
- `checkRateLimit` (ConcurrentHashMap, `ReentrantLock`): already has a pure-Lyric twin (`_kernel/net/web_kernel.l`, uses `Ws.Kernel.Net` locks). It should be shared, not per-target; once `Ws.Kernel.Net` covers the JVM (section 3) the JVM branch of lyric-web can use the same file.
- Static files: `pathGetFullPath` JVM variant (`java.io.File.getCanonicalPath`, `web.l` lines 336-352) stays; it is not part of the server and is a small per-target seam like dotnet's and native's (`@cfg`-selected). Keep.
- WebSocket upgrade: today `Ws.Kernel.Jvm` mounts endpoints on Undertow's `PathHandler`. After the change it uses the same `serveWebSocketUpgrade` + `takeConnection` + `adoptConnection` path as dotnet/native (`web.l` ~2084, `upgradeWebSocket` in `net/web_kernel.l`, V).
- OpenAPI: `openapi.l` is pure Lyric; no JVM-specific code (V by absence of `@cfg` in the listing; A for a full read).

### 2.2 Migration to one `Web.serve` path

1. Widen `@cfg(any(feature = "dotnet", feature = "native"))` to include `"jvm"` on the shared serve section of `web.l` (about 25 annotated declarations between lines 1637 and 2631). Delete the `@cfg(feature = "jvm") pub func serve`/`serveTls` at lines ~2288 and ~2477, and the duplicate `serveTls` misconfiguration check (the shared `startListenerTls` returns `InvalidConfig`).
2. Collapse `Web.Kernel.Runtime` to: shared `web_kernel.l` (rate limiter, `startWorkerLoop`, `spawnRequestJob`, `upgradeWebSocket`) plus three tiny per-target prims files (`net`, `native`, new `jvm`) holding only `runJobGuarded`, `tickGuarded`, `runAcceptStep` (the try/catch family, V from `net/web_prims.l` and `native/web_prims.l`). Rename `_kernel/net/` to something neutral only if cheap; otherwise leave the directory name.
3. The cross-error-type JVM miscompile recorded at `web.l` ~2455-2470 (a nested `match` on `Result[_, TlsListenError]` inside a function returning `Result[_, ServeTlsError]` throws `ClassCastException` on the JVM, the #5903 family) is a risk: the shared `serveTls` does exactly that match (`web.l` ~2426). Verify in S0 whether it is fixed; if not, fix the compiler bug (root cause, not a workaround), since the standard forbids papering over it.
4. Gains on the JVM: `serveStreaming` (README "Known gaps": streaming is dotnet-only), per-request crash isolation consistent with dotnet, `Web.addWorker`, h2 with the same limits. Behaviour differences to document: request header names keep wire casing from the engine (Undertow and the JDK server normalised them; lyric-web already folds case, V per the JVM kernel header), request body bytes are preserved rather than decoded as UTF-8 unconditionally.
5. Remove from `lyric-web/lyric.toml`: the `[maven]` table, the `jvm` kernel file entry `src/_kernel/jvm/web_kernel.l`, and the comments describing the Undertow split. Delete `src/_kernel/jvm/web_kernel.l`, `tests/jvm_server_smoke.l`'s Undertow framing (convert it into a target-neutral smoke over `Web.serve`/`serveTls`; keep its HTTPS-H2, mTLS accept and reject, misconfiguration and body-cap checks, which exercise real behaviour) and `scripts/ci/lyric-web-undertow-jvm-smoke.sh`. Rename the script to `lyric-web-jvm-smoke.sh` (drops the `restore` and `make maven-resolver` steps, which also removes a `flock`-serialised slow step from `compiler-self-tests-jvm-c`) and keep the `curl --http2` cross-check and the 10 MiB boundary checks (exactly-at-limit echoed, one byte over is 413 for Content-Length, chunked and GET, #7233 and #7325, V in the script).
6. Docs: `lyric-web/README.md` (the "JVM target" and "Known gaps" sections, lines ~244 and ~519-533), `book/chapters/24-web-services.md`, `book/chapters/14-jvm-target.md`, `book/chapters/29-application-libraries.md`, `book/chapters/appendix-b-quick-reference.md`, `docs/44-jvm-production-readiness-plan.md` (lines ~474 and ~653-677), `docs/59-compiler-stdlib-deep-review.md` (lines ~88, ~139), `docs/61-https-tls-http-versions.md` (table rows at lines 19-25, decision 6, section 6.5), and CLAUDE.md's `lyric-web` and `lyric-ws` bullets (the `lyric-ws` bullet still says "ASP.NET Core WebSockets on .NET, Undertow on JVM", already stale).

## 3. lyric-ws

### 3.1 What the shared kernel already provides (V)

`Ws.Kernel.Net` is one package in three files (`lyric-ws/lyric.toml` lines 18-24): `net/ws_kernel.l` (992 lines, RFC 6455 server over `Std.TcpHost`), `net/ws_prims.l` (dotnet, 138 lines) and `native/ws_prims.l` (224 lines). Frame codec (`ws_frame.l`, 597 lines: masking, lengths, control-frame rules, fragmentation reassembly capped at `maxMessageSizeBytes`, close-code validation, UTF-8 validation, RSV must be zero) and handshake (`ws_handshake.l`, 420 lines: accept key, origin policy) are already pure and target independent (their test suites run on both targets).

The per-target prims the JVM twin must provide, with the dotnet and native signatures as the contract:

- `WsLock` with `newWsLock`, `lockEnter`, `lockExit`, `releaseWsLock` (dotnet `Monitor`, native pooled mutexes; JVM `ReentrantLock`, `release` a no-op).
- `ConcurrentDict[K, V]` with `newConcurrentDict`, `cdTryGetValue(..., value: out V)`, `cdTryAdd`, `cdTryRemove` (dotnet `ConcurrentDictionary`; native a locked map; JVM `ConcurrentHashMap` via extern type. Precedent: lyric-web JVM `JvmConcurrentDict`. Watch the #5443 alias-collision bug: the JVM prims file is selected by `@cfg`, but the package is multi-file, so keep alias names unique).
- `runBackground(work)` (JVM virtual thread; closure-to-Runnable record as in `_kernel_jvm/task.l`).
- `threadSleep(ms)` (JVM `Thread.sleep`).
- `guardOnOpen/Message/Close/Error` (try/catch isolation; JVM `catch Bug`, dotnet uses `catch Exception`, native none) and `acceptShouldContinue` (pure, can move to the shared file).

Ideally `Std.HttpServerHost` (section 1.2) exposes `Mutex` and `spawn`, and `Ws.Kernel.Net` reuses them so there is one prims set in the repository instead of three. The concurrent dictionary and guard family remain `ws_prims.l` because lyric-ws owns them. Decision: reuse `Std.HttpServerHost` for lock and spawn only if it is public enough to import from an ecosystem package, otherwise keep the three-file pattern and add a JVM `ws_prims.l` (about 150 lines). Recommended default: keep the three-file pattern in S7, consolidate later if the stdlib grows a public concurrency module (open question).

### 3.2 Port steps

1. Add `src/_kernel/jvm/ws_prims.l` (package `Ws.Kernel.Net`, `@cfg(feature = "jvm")`) and widen `ws_kernel.l`'s `@cfg(any(feature = "dotnet", feature = "native"))` to include `"jvm"`.
2. Resolve the public API twins in `ws.l`: it has paired `kernelStartServer`, `kernelStopServer`, `kernelSend`, `kernelBroadcast`, `kernelClose`, `kernelConnectionCount`, `kernelIsConnected`, `kernelCreateEndpoint`, `kernelCreateRegistry`, `checkRateLimit` per feature (lines 67-234, V). Collapse to the single `Ws.Kernel.Net` path.
3. Delete `src/_kernel/jvm/ws_kernel.l` (921 lines, 35 extern types), the `Ws.Kernel.Jvm` package entry, the `[maven]` table and the `jvm` feature wording in `lyric-ws/lyric.toml`. Keep the `jvm` feature flag (it is the target selector) with new wording.
4. Tests: `tests/ws_dotnet_e2e_tests.l` (596 lines; 8 loopback tests: echo, binary and fragmented, ping/pong, send and broadcast from outside callbacks, cross-origin 403, same-origin headers, empty close mapped away from 1005, handler-throws isolation) imports `Std.TcpHost`, so it can now run on the JVM (D611). The only target-specific line is the `System.Threading.Thread.Sleep` extern at line 42-45; replace with a per-target sleep (a tiny `@cfg` shim or a stdlib sleep if one exists; check `Std.Time`/`Std.Task.delay` first, A). Rename to `ws_e2e_tests.l`, register it for all three targets, drop the "dotnet-only" comment in `lyric.toml`, and remove `Ws.WsDotnetE2eTests` from the exclusion in `scripts/ci/jvm-ecosystem-suites.sh` (lines 111-115). `tests/ws_jvm_origin_smoke.l` and `scripts/ci/lyric-ws-undertow-jvm-smoke.sh` are subsumed by the e2e origin tests and are deleted (the smoke covered the 403 cross-origin policy, #7243).
5. Add the JVM to the native-style smoke: `scripts/ci/` has a native lyric-web/lyric-ws smoke (ci.yml ~2833); make a JVM sibling script.

### 3.3 Feature checklist (current state V, then work)

| Feature | pure-Lyric dotnet/native today | Work |
|---|---|---|
| Fragmentation, UTF-8 validation, size cap | yes (`ws_frame.l`) | none; JVM gains it |
| Ping keepalive | yes (`runPingLoop`, interval from `LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS`, default 30000) | JVM gains it |
| Pong handling | peer pong is reported as a "pong" message; replies to peer ping | none |
| Close handshake | `sendCloseIfNotAlready`, echo of peer close, 1005 never sent | covered by e2e test |
| Origin checks | `Ws.Handshake.requestOriginAllowedFor` with `allowedOrigins`/`sameHostPorts` | none |
| Registry and broadcast | `registryMap`/`connMap` concurrent dictionaries; `broadcast` is a serial loop over a snapshot | needs slow-consumer fix below |
| Backpressure and slow consumers | none: `hostSetIoTimeout(conn, 0)` (line 663) so a stalled peer blocks its writer forever; `broadcast` holds each connection lock sequentially, so one stalled client stalls every other client's delivery | S8: per-connection write timeout (`hostSetIoTimeout`), bounded per-connection outbound queue with a writer thread or timed `send`, and a broadcast that does not serialise on slow peers; close with 1008 or 1013 and `onError` when exceeded |
| Connection cap, idle timeout | none | S8: reuse `LYRIC_HTTP_MAX_CONNECTIONS`-style limit (`Ws` options), idle timeout tied to ping/pong liveness |
| TLS (wss) | `startServer` has no TLS parameter; `wss` works only via lyric-web `serveTls` plus `takeConnection` (the returned `Conn` is a TLS `Conn`, V) | S8: add `startServerTls` over `hostAccept`+`hostUpgradeServerTlsPrepared`; or document the `Web.addWebSocket` route as the TLS path. Recommendation: add it, since JVM `Ws.startServer` over Undertow offered `addHttpsListener` previously (A, not verified in the 921-line file) |
| permessage-deflate (RFC 7692) | not supported: `tryParseFrame` rejects RSV bits ("no WebSocket extensions negotiated", `ws_frame.l:246`) | optional, decision needed (section 7). `Std.Zip` provides pure-Lyric DEFLATE (D248, per CLAUDE.md), but verify it has a raw streaming deflate/inflate with context takeover and a no-context-takeover mode before committing (A). Estimate L. Not required for parity with Undertow's current ws kernel (A: Undertow ws in this repo configures no extensions, no mention found by grep) |
| Subprotocols | none | out of scope; record as a tracked gap if not already |

Autobahn (section 4.3): the pure-Lyric server is the first implementation that can be run against the Autobahn testsuite on all targets; fixing what it finds benefits dotnet and native too.

## 4. Test and conformance strategy

### 4.1 Unit and in-process e2e on all three targets

- Make the server suites target-neutral. `http_server_dotnet_tests.l` (33 tests, V list at lines 432-1316) is dotnet-only because its puller uses `System.Threading.Tasks.Task.Run` externs and the h2 cases use the Lyric HTTP client. Rework into `http_server_tests.l` run on dotnet, JVM and native with a per-target spawn shim kept inside the test file (the documented test-only exception to the kernel-only extern rule, as `tcp_host_tls_tests.l` does). Native: its native-only items stay in `llvm_http_server_self_test.l` (1588 lines).
- Keep `http_engine_tests.l` (74), `http_h2conn_tests.l` (83), `http_h2frame_tests.l`, `http_hpack_tests.l` on all three; they are the security-boundary corpus and already run on the JVM.
- New shared tests: `stopListener` regression map (section 1.6), `takeConnection` (3 existing dotnet cases port directly), connection cap (`LYRIC_HTTP_MAX_CONNECTIONS=1` backpressure), idle and handshake timeouts (4 existing cases), body-limit boundaries on h1 and h2.
- Replace `http_server_jvm_tests.l` (4 tests, JDK-server body cap) and fold `tls_server_jvm_tests.l` into the shared suite where it is not target specific.
- lyric-web suites (`dispatch`, `cors_guard`, `rate_limit`, `security_aspect_weaving`, `serve_tls`, `webtls_config`, `serve_crash_isolation`, `worker_dispatch`, `web_socket`, `concurrent_dispatch`, plus `streaming_tests.l` and `serve_failure_tests.l`, V file list) must all pass on the JVM; `streaming_tests.l` newly applies to the JVM.

### 4.2 TLS and h2 interop

- curl with `--http2`: already used in CI (`scripts/ci/dotnet-h2-smoke.sh`, ci.yml ~7304, and the Undertow smoke script). Add a JVM equivalent and a native one when native gains h2.
- Independent h2 conformance: `h2spec` (a Go binary) and `nghttp` are not in CI today (V: grep found no references). `nghttp2-client` (`nghttp`, `h2load`) installs from apt on ubuntu runners (A: confirm the CI image and network policy allow apt). Recommendation: run `h2spec -t -k` (TLS, skip verify) in a nightly or path-filtered job against the shared server on one target, since the driver is shared and a second target adds little h2 coverage. The H2Conn FSM is already corpus-tested (83 tests), so h2spec is a cross-implementation check, not the first line.
- JDK `HttpClient` as an h2 client: `Std.Http` on the JVM already uses it and reports `negotiatedVersion()`. dotnet `HttpClient` as an h2 client: Std.Http on dotnet defaults to h2-or-lower since D128 (V per docs/61). Keep both as the in-process interop pair for every target pair.
- TLS matrix: TLS 1.2 floor, TLS 1.3 only, mTLS accept and reject, SAN fixtures reused from `tcp_host_tls_tests.l`.

### 4.3 Autobahn (WebSockets)

The Autobahn testsuite (`crossbario/autobahn-testsuite`, Docker image, Python 2 based, with a newer Python 3 successor) acts as a client against a Lyric echo server. Feasibility in CI is plausible but not yet verified (A): it needs Docker and the image pull, which the CI network policy must allow, and a full run takes roughly 10 to 20 minutes with permessage-deflate cases excluded. Recommendation: a nightly job, not per-PR, running against a Lyric echo server built with each of dotnet and JVM (shared code, so one target is the real signal; the JVM is first because it gains the pure-Lyric server). Pass criteria: no `FAILED` case in sections 1 to 7 and 9 to 10; section 12 and 13 (deflate) either implemented or listed as `UNIMPLEMENTED` in a checked-in expected-results file. Script under `scripts/ci/`, one workflow step.

### 4.4 Load, soak and the Undertow baseline

Do this in S0, before any deletion: record numbers from the current Undertow stack, the current JDK-server kernel and the dotnet engine on the same runner class, so the acceptance thresholds rest on measurement. Tooling (A, verify availability): `wrk` (apt) for HTTP/1.1 keep-alive, `h2load` from `nghttp2-client` for h2, and a small Lyric load client (using `Std.TcpHost` over loopback) for idle-connection and slow-client scenarios if the others are missing.

Benchmark definition (`benchmarks/http_server/`, a Lyric program that starts the server plus a script driving it):

| Scenario | Load | Metric |
|---|---|---|
| B1 hello, h1 keep-alive | `wrk -t4 -c64 -d30s`, handler returns "ok" | requests/s, p50, p99 |
| B2 hello, h1 connection per request | `wrk` with `Connection: close` | requests/s, accept-loop cost |
| B3 echo 64 KiB body, h1 | POST with body | MB/s, allocation rate |
| B4 hello, h2 over TLS | `h2load -n200000 -c32 -m10` | requests/s, p99 |
| B5 10 000 idle keep-alive connections, plus a trickle of requests | custom client | RSS, live threads, p99 under idle load |
| B6 soak | B1 at 50% of peak for 30 minutes, with connect/disconnect churn | RSS drift, fd count, thread count, error count |
| B7 WebSocket fan-out | 1000 connections, broadcast 1 KiB at 10 Hz | broadcast latency p99, drops |

Proposed acceptance thresholds (a starting position to be re-set from S0 measurements, then fixed in the decision record): for B1 and B4, at least 60% of the Undertow baseline throughput and p99 within 2x; B3 at least 50%; B5 RSS within 1.5x of Undertow at 10 000 idle connections with zero failed requests; B6 no RSS growth beyond 10% after warm-up, no fd or thread leak, zero errors; B7 p99 within 2x. Rationale: docs/61 section 6.5 already requires "throughput within a documented factor" for the dotnet convergence; a hand-rolled server on virtual threads should land near Undertow for keep-alive hello but the unbuffered JDK socket path (section 0 item 4) and the per-request thread hop must be measured. If B1 falls below 60%, S1 (buffered reads, write path) and the optional push entry point (section 1.3) are the first levers before accepting the regression.

### 4.5 Failure injection (all shared, run on every target)

Slow-loris headers (one byte per second; expect the idle timeout to close it and the connection permit to be released), slow body, slow reader (client never reads a large response; expect the write timeout and permit release), half-open (peer vanishes without FIN; relies on idle timeout, optionally TCP keepalive via `hostSetKeepAlive`, to be added if absent), oversized request line, header count, header total and body (431/414/413 mapping as the engine returns), 20 000 simultaneous connection attempts against a cap of 1000 (permit backpressure, no thread explosion, listener still accepts after drain), TLS handshake stalls (silent peer, garbage ClientHello, wrong ALPN), h2 rapid reset and CONTINUATION flood (engine already limits, `maxRapidResets`, `maxContinuationFrames`, V), abrupt client close mid-response for both h1 chunked and h2. Several exist already (#7268, #6566, #7859 pipelining, #7265 header folding).

## 5. Risks and decisions

1. **Performance versus Undertow.** The largest risk. Mitigations: S0 baseline, S1 transport tuning (buffered `InputStream` wrapper so `read`/`available`/`readNBytes` become one syscall in the common case; avoid per-read `ByteArrayOutputStream`; replace the per-write virtual-thread watchdog with a per-connection deadline checked by one shared timer, or use `SocketChannel` with a timeout; avoid copying request bodies through `List[Byte]`). Each tuning item must show up in B1/B3/B4 before and after. Gate S4 on the thresholds.
2. **Loss of Undertow features.** What users lose by moving off Undertow: its HTTP/1.1 server-side tuning options, access logging hooks, `ENABLE_HTTP2` h2c upgrade (not enabled today for plaintext, V: only set with TLS), Undertow's WebSocket extensions (none configured, A), and any user-written Undertow handlers reaching into the `Web.Kernel.Runtime` internals (package-level, not documented API). Gains: h2 and TLS behaviour identical to dotnet, `takeConnection`, streaming, limits and timeouts, identical `Web.serve` semantics. Applications that relied on Undertow arriving transitively through lyric-web's Maven dependency must declare it themselves.
3. **h2 on the JVM through the engine.** `H2Conn` is proven by the corpus on the JVM; the driver's h2 half (~900 lines, the send scheduler) is the part to prove (S4 gate). Known stress points: threadpool-starvation analogue on the JVM (none expected with virtual threads, but the h2 reader and connection tasks block on semaphores; pinning check), and the rejected-stream bookkeeping (`pruneRejectedStreams`).
4. **Keep the JDK HttpServer as a fallback? Recommendation: no.** It has no `takeConnection`, no h2, no handshake or idle timeouts, no connection cap, and the engine-vs-JDK behavioural differences (header casing, body decoding) are exactly why two JVM paths hurt. A fallback keeps a second kernel to maintain and test, contradicting the "no one-platform implementations" standard. Rollback is a pinned previous release. Undertow is still reachable for any application through its own `extern type` binding.
5. **Compatibility.** Public signatures of `Web.serve`, `Web.serveTls`, `Ws.startServer*`, `Std.HttpServer.*` are unchanged or additive. Breaking items to record in the decision: removal of `Ws.Kernel.Jvm`, removal of the `[maven]` Undertow coordinates in lyric-web/lyric-ws manifests, JVM header-name casing, `HttpContext` becoming a Lyric record on the JVM (source compatible for inference users; direct users of `com.sun.net.httpserver.HttpExchange` methods on it break), `TlsListenError` gaining `.message`/`InvalidConfig` on JVM.
6. **lyric-ui.** The web host (`lyric-ui` U2, JVM parity shipped #7378/D139) uses `Lyric.Ws` through lyric-web and reaches Undertow only transitively (`scripts/ci/ui-jvm-suites.sh` header, V). After S6/S7 the UI suites run on the shared path; action: remove the Maven restore from `ui-jvm-suites.sh`, run the UI browser e2e once on the JVM (CI step exists for ui e2e, ci.yml ~6554 region, A for exact step) and keep the pure-Lyric session and reconnect behaviour as the acceptance. Slow-consumer handling from S8 directly benefits UI (server pushes diffs over `Ws.sendText`).
7. **lyric-grpc.** dotnet already runs a pure-Lyric h2c server on `Std.HttpEngine.H2Conn` in `lyric-grpc/src/_kernel/net/grpc_server.l` (813 lines, V by CLAUDE.md and file listing); the JVM uses grpc-java (692-line kernel with a Maven dependency). That h2c driver is a second consumer of the same transport and h2 scheduling ideas. Out of scope here. Note for the future pure-Lyric gRPC plan: factor the h2 connection scheduler out of the HTTP driver so `Std.HttpServer` and gRPC both use one h2 server loop (h2c, plaintext, prior knowledge). Do this only after S3/S4 settle the shared driver; do not block this plan on it.
8. **Compiler fixture dependency on Undertow.** Retarget before removing: use grpc-java (kept in lyric-grpc, still a Maven dependency) or a small pinned Maven fixture jar for `jvm_auto_ffi_bridge_self_test.l`, `cli_build_self_test.l:1081`, `cli-args-e2e.sh:186` and `manifest-jvm-maven-test.sh`. Those tests exist to prove Maven classpath resolution and `impl <ExternInterface>`; they must keep a real third-party library.
9. **Compiler risk surface.** The driver is the largest shared Lyric program compiled for the native and JVM backends so far. Expect backend bugs (ref record `var` fields, generics over extern payloads #2494, JVM cross-package union match #5903, closure-in-closure T0123). Per the standard, fix root causes in the compiler in their own PRs rather than reshaping the driver around them; budget for it in the S3 and S4 estimates.

## 6. Slices (independently shippable)

Dependency graph: S0 first. S1 needs S0. S2 needs S0. S3 needs S1 and S2. S4 needs S3. S5 needs S3 (independent of S4). S6 needs S4. S7a needs only S1 (and S7 prims), so it can run in parallel with S3 and S4. S7b (Web.addWebSocket on the JVM) needs S4 and S6. S8 needs S7a. S9 needs S6 and S7b. The h2 client-role plan is a separate plan and is not required here.

**S0. Baseline, spikes and decisions (M).** Deliver `benchmarks/http_server/` with the B1-B7 scenarios and a script under `scripts/ci/`, recorded numbers for Undertow, the JDK-server kernel and the dotnet engine in a progress note. Spikes (throwaway branches, results recorded): (a) a reduced driver (accept loop plus mutex/semaphore FIFO plus one h1 connection loop) compiled and run on dotnet, JVM and native to confirm ref records, closures into the seam and `try`-free structure work, and that a `Std.HttpServer` (shared) plus `Std.HttpServerHost` (kernel) package split loads on all three loaders and builds per-package DLLs/JARs; (b) JDK 21 virtual-thread pinning check for `SSLSocket`; (c) the cross-error-type JVM miscompile at `web.l` ~2455; (d) availability of `wrk`, `nghttp2-client`, Docker for Autobahn on the CI image. Acceptance: numbers committed, thresholds fixed in a decision entry D614, spike outcomes listed, remaining open questions resolved or re-scoped. Docs: decision D614, progress entry. No product code ships.

**S1. `Std.TcpHost` fit for a server on dotnet and JVM (M).** _Shipped in D621 (`docs/decisions/D621-tcphost-server-ready.md`, `docs/progress/2026-11-19-tcphost-server-ready.md`): all items below done except `hostSetKeepAlive` (not needed, recorded in D621); the B1 acceptance is met for latency and messages up to 1 KiB and NOT for 16 KiB and larger messages (3.5x and 8.5x slower than dotnet), the cost being the boxed `slice[Byte]` representation on the JVM, see the progress note._ JVM: buffered reads and a cheaper read path, a write timeout without a virtual thread per write, `hostShutdown`, listen backlog, `hostSetKeepAlive` if the targets lack it, move the server `SSLContext` construction out of `_kernel_jvm/http_server.l` into the JVM TCP kernel (breaks the cycle). dotnet: `hostShutdown`. All targets: tests in `tcp_host_tests.l`/`tcp_host_tls_tests.l` for shutdown-unblocks-read and timeouts. Acceptance: existing `Std.TcpHost` suites green on all targets; B1 transport microbenchmark shows the JVM read/write path no slower than 2x dotnet loopback; `Std.HttpServer` JVM kernel still works unchanged (it imports the moved helpers). Docs: decision (supersedes nothing; extends D611), progress, docs/61 section 7 transport table.

**S2. `Std.HttpServerHost` seam on three targets (S-M).** `spawn`, `Mutex`, `Semaphore`, `runGuarded`, `WorkerSet`, with unit tests on each target (mutual exclusion, semaphore counting, spawn runs, guard catches on dotnet/JVM, join semantic on native). Acceptance: tests green on all three; native `lyric_*` mappings reuse the existing runtime primitives. Docs: kernel README (`lyric-stdlib/std/_kernel*/README.md`), progress.

**S3. Shared driver, adopted by dotnet (L).** Create `lyric-stdlib/std/http_server.l`; migrate the dotnet kernel into it using the S2 seam, keeping every dotnet behaviour (h1, h2 with the scheduler, limits, timeouts, takeConnection, chunked). Add the generalised stop contract and `stopping` flag; add `WithLimits` and `resolve*` to the shared surface. dotnet-only code that remains: nothing in `_kernel/http_server.l` (deleted). Native keeps its kernel (the loader prefers `_kernel_native/http_server.l` by basename; the shared file is only the dotnet and later JVM path until S5, which must be spelled out in the decision so there is a dated, tracked end to the duplicate). Acceptance: all 33 dotnet server tests, the h2 curl smoke, `dotnet_h2_smoke`, lyric-web and lyric-ws dotnet suites green; B1-B4 not slower than 90% of the pre-refactor dotnet numbers; new stop-race tests pass on dotnet. Docs: decision D615 (shared driver architecture, the per-target seam, supersedes D128 section 6.1/6.2's per-kernel statement), progress, docs/61 updates (sections 6.2, 6.5, 7), `lyric-stdlib/std/_kernel/README.md`.

**S4. JVM adopts the shared driver; JDK HttpServer removed (L).** Delete `_kernel_jvm/http_server.l` (1059 lines); add `_kernel_jvm/http_server_host.l`; port server tests to JVM; add JVM h2 curl smoke script; remove `http_server_jvm_tests.l` (superseded); keep `tls_server_jvm_tests.l` cases that are target independent. Acceptance: the neutral server suite green on dotnet and JVM; the benchmark thresholds met (B1-B6); curl `--http2` returns `2:200`; stop-race and failure-injection tests green on JVM; lyric-web still uses Undertow at this point (it does not call `Std.HttpServer` on the JVM yet), so nothing else changes. Docs: decision D616 (JVM convergence per docs/61 section 6.5; records measured numbers), progress, docs/61 (table rows, decision 6), docs/44, docs/59, CLAUDE.md note on `Std.HttpServer`.

**S5. Native adopts the shared driver and gains h2 (L).** Replace `_kernel_native/http_server.l` (2018 lines) with `_kernel_native/http_server_host.l`; native gains h2 over ALPN (closes #6106), `WithLimits`, full surface; keep every native stop fix (#6791-#6806) as seam-level obligations plus the native self-tests in `llvm_http_server_self_test.l`. Acceptance: that self-test suite green under ASan; native h2 curl smoke; benchmark B1 and B4 within 90% of pre-refactor native. Risk: native codegen limits (`inout`, `String[i]`, closure lifetime); budget compiler fixes. Docs: decision, progress, docs/61 section 7, `docs/native-plan/08-work-items.md` N9.5.

**S6. lyric-web unified (M).** Section 2.2. Acceptance: the whole lyric-web manifest suite on dotnet, JVM and native; `tests/streaming_tests.l` on the JVM; the neutral smoke script with h2, mTLS and body-cap checks; Maven table and `lyric-web-undertow-jvm-smoke.sh` removed; no CI step restores Undertow for lyric-web. Docs: lyric-web README, book chapters 14, 24, 29 and appendix B, docs/44, CLAUDE.md bullets, decision D617 (breaking changes list), progress.

**S7a. lyric-ws on the JVM over `Std.TcpHost` (M).** Section 3.2 steps 1-4 for `Ws.startServer`. Depends only on S1. Acceptance: `ws_e2e_tests.l` (the 8 loopback tests) green on JVM, dotnet and native; `ws_tests`, `ws_frame_tests`, `ws_handshake_tests`, aspect tests unchanged; Undertow ws kernel and smoke deleted. Docs: lyric-ws README, docs/62 section 6, book, CLAUDE.md, decision D618, progress.

**S7b. `Web.addWebSocket` over `takeConnection` on the JVM (S).** Depends on S4 and S6. The shared `web_socket_tests.l` runs on the JVM; the origin smoke through Web. Acceptance: `lyric-ui` web host e2e on the JVM; remove `[maven]` from lyric-ws.

**S8. lyric-ws hardening on all targets (M each, independent PRs).** (i) Per-connection write timeout and a bounded outbound path so one slow consumer cannot stall broadcast (acceptance: B7 and a failure-injection test with a client that stops reading); (ii) connection cap and idle timeout tied to ping liveness; (iii) `startServerTls` (wss) with an e2e test; (iv) Autobahn nightly (section 4.3) with a checked-in expected-results file; (v) permessage-deflate, only if the decision in section 7 says yes (L). Each carries its own decision and progress entry.

**S9. Cleanup and fixtures (S).** Retarget the compiler Maven fixtures off Undertow (section 5 item 8), delete dead scripts (`lyric-ws-undertow-jvm-smoke.sh`, `lyric-web-undertow-jvm-smoke.sh`), update `scripts/ci/detect-code-changes.sh` (line ~221), `jvm-ecosystem-suites.sh` comments and `ui-jvm-suites.sh`, edit ci.yml in place (net size reduction). Acceptance: no `undertow` string remains outside the decision archive and progress history (`grep -ri undertow` clean in code, scripts, manifests, READMEs, book); `ci.yml` size at or below its current size.

Estimates: S0 M, S1 M, S2 S-M, S3 L, S4 L, S5 L, S6 M, S7a M, S7b S, S8 M per item (L for deflate), S9 S. S1, S2 and S7a can proceed in parallel after S0.

CI notes: all new steps are single lines calling `scripts/ci/*.sh` (ci.yml has 511 bytes of headroom; replace the two Undertow steps rather than adding). New jobs for soak and Autobahn are nightly (`schedule`), not per-PR. The `make maven-resolver` flock-serialised steps for lyric-web and lyric-ws disappear, which shortens the `compiler-self-tests-jvm-c` job.

Per-slice documentation duty, per CLAUDE.md: a decision file `docs/decisions/D6NN-*.md` (start at D614), a progress file `docs/progress/2026-MM-DD-*.md`, update `docs/10-bootstrap-progress.md` status sections, docs/61 (status header and section 6.5, since the JVM convergence criteria are met or amended), book chapters 14 (JVM), 24 (web services) and 29, and appendix B, README of each touched library, and the toolchain table in `book/chapters/01-getting-started.md` only if a CLI-visible item changes (none expected). Each slice also lists its removed pre-existing caveats ("a permanent difference", "dotnet-only") so none survives as stale text.

## 7. Open questions needing a decision

1. **Performance gates.** Are the proposed thresholds (60% of Undertow throughput, p99 within 2x, RSS within 1.5x) acceptable, or should the gate be relative to the dotnet engine instead? Needs S0 numbers.
2. **Package split mechanism.** `Std.HttpServer` (shared) plus `Std.HttpServerHost` (kernel). Confirm against the loader and per-package build in S0, because #5932/D-progress-889 documented a multi-file hazard. Alternative if the split fails: keep one kernel file per target and accept duplication only temporarily with a dated tracking issue (the standard disfavours this).
3. **Public vs internal seam.** Should lock/spawn/semaphore be a public stdlib module (`Std.Sync`, `Std.Thread`) that ecosystem packages (lyric-ws, lyric-web, lyric-grpc) can also use, instead of three per-library prims files? It would collapse `ws_prims.l`, `web_prims.l` and the `Std.HttpServerHost` seam, but it is a language-library design decision (protected types and `Std.Task` exist; native lacks `when:` barriers on protected types per D-N-017 so they cannot yet replace mutex+semaphore).
4. **`nextContext` after stop.** Return a sentinel, panic, or block forever (native today blocks the join semantics differently)? Recommended: a documented panic or an `Option`-returning variant, with the old signature kept for compatibility.
5. **Push-style dispatch.** Add `serveHandler(listener, handler)` to skip the pull-queue hop, if S0 shows the hop costs more than ~10% on B1.
6. **`stopListener` blocking.** Native blocks until all connection threads exit; dotnet does not. Should the shared contract be "returns after connections are closed and threads exited" on every target (recommended, with a bounded grace period setting) or "returns after the listener is closed"?
7. **permessage-deflate.** Implement (L, depends on `Std.Zip` streaming deflate and context takeover) or document unsupported with a clean negotiation refusal? Recommendation: unsupported for this effort, because neither the Undertow kernel (A) nor the pure-Lyric one supports it, and Autobahn sections 12-13 can be listed as expected-unimplemented; tracked as its own issue.
8. **wss in `Ws.startServer`.** Add `startServerTls`, or document `Web.addWebSocket` plus `Web.serveTls` as the supported TLS route and keep `Ws.startServer` plain-only?
9. **`startServer` on the JVM: virtual-thread-per-connection with a cap, or a larger default cap than 1000** (JVM can sustain far more idle connections than a thread-per-connection native build)? Per-target default for `LYRIC_HTTP_MAX_CONNECTIONS`, or one portable default.
10. **Test shim for the puller thread.** The neutral server tests need a background puller. Per-target `@cfg` extern shim in the test file (documented exception), or a public test-support helper in `Std.Testing`? Check that `@cfg` works inside a `@test_module` for the `target`/feature combination in use (A).
11. **lyric-grpc.** Factor a shared h2 connection scheduler out of the HTTP driver for the planned pure-Lyric JVM gRPC server, or keep grpc-java until that plan lands? This plan assumes the latter.
12. **Compatibility window.** Clean break on `Ws.Kernel.Jvm` and the Maven coordinates (recommended, matches the "no deprecation window" precedent of D132), or one release with both? The production standard favours the clean break.
13. **Header casing.** Preserve wire casing (engine behaviour) on all targets (recommended), documenting the JVM difference as a fix of a JDK normalisation artifact.

### Critical Files for Implementation
- lyric-stdlib/std/_kernel/http_server.l
- lyric-stdlib/std/_kernel_jvm/tcp_host.l
- lyric-stdlib/std/_kernel_native/http_server.l
- lyric-web/src/web.l
- lyric-ws/src/_kernel/net/ws_kernel.l