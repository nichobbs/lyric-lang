//! std/_kernel/http_server.l - dotnet HTTP/1.1 server assembly on the
//! sans-IO `Std.HttpEngine` + `Std.TcpHost` transport
//! (docs/61-https-tls-http-versions.md §6.1/§6.2/§6.3, D128; phase 3.3 of
//! epic #5874, issue #5884).
//!
//! This file replaces the former `System.Net.HttpListener`-based server. The
//! `HttpListener` externs are gone: nothing here reaches the BCL HTTP stack.
//! The server is now three composed layers, each already shipped and tested:
//!
//!   * **Transport** — `Std.TcpHost` (`_kernel/tcp_host.l`, #5882):
//!     `System.Net.Sockets.TcpListener` + `System.Net.Security.SslStream`,
//!     `Result[_, TcpError]` throughout.
//!   * **Protocol** — `Std.HttpEngine` (`std/http_engine.l`, #5883): a pure
//!     Lyric, sans-IO HTTP/1.1 parser + serializer + per-connection FSM. This
//!     file never parses a byte of HTTP itself; it pumps transport bytes into
//!     `feed` and writes `serializeResponseHead`/`serializeChunk` output back.
//!   * **Concurrency** — a structured accept loop (docs/61 §6.2): a background
//!     `Task` accepts connections and spawns one per-connection `Task` each,
//!     which drives its own `Std.HttpEngine.Connection`. Lyric `spawn`/`scope`
//!     is degenerate-synchronous on `--target dotnet` (D119/D120), so the real
//!     OS-thread concurrency comes from `System.Threading.Tasks.Task.Run` —
//!     the same background-thread mechanism `tcp_host_tls_tests.l` uses to run
//!     an in-process loopback server. This fixes the single-threaded
//!     "bootstrap-grade" concurrency deficiency the old `HttpListener` loop
//!     carried, in the same change as TLS.
//!
//! ## Preserved public surface (pull model)
//!
//! The twelve-function `Std.HttpServer` surface (`startListener` /
//! `nextContext` / `stopListener` / `requestMethod` / `requestPath` /
//! `requestBody` / `requestQuery` / `requestHeaders` / `urlDecode` /
//! `respondText` / `respondJson` / `respondBytesWithHeaders`) plus the three
//! chunked-streaming helpers (`beginChunkedResponse` / `streamWriteChunk` /
//! `endChunkedResponse`) are unchanged in name and semantics, so `lyric-web`
//! and every other consumer keeps working without a source edit
//! (`startListenerWithLimits` / `startListenerTlsWithLimits` are additive, for
//! callers that need to raise the engine's request-size caps, and so is
//! `takeConnection`, which hands an HTTP/1.1 connection to another protocol
//! after an `Upgrade` request, D146). `HttpContext`
//! and `HttpListener`, formerly extern aliases for BCL types, are now Lyric
//! records — they are returned/held by consumers but never named as extern
//! types, so the shape change is source-compatible. The chunked-stream handle
//! (formerly the `System.IO.Stream` extern) is now the Lyric record
//! `HttpChunkedStream`; consumers bind it by inference (`val s =
//! beginChunkedResponse(...)`), so the rename is source-compatible too.
//!
//! The model is still pull-based: a per-connection background task parses one
//! request, hands a ready `HttpContext` to a shared blocking queue, and blocks
//! until the puller responds (via a per-context one-shot `done` mailbox). The
//! puller thread — the caller's own `while true { nextContext ...; respond ... }`
//! loop — owns response writing; the connection task owns request reading. The
//! two never touch the socket concurrently (the per-request handshake enforces
//! strict alternation), and many connections are read/parsed concurrently on
//! their own tasks while the puller dispatches one request at a time — the
//! concurrency win over the old serialized `HttpListener.GetContext` loop.
//!
//! ## `startListenerTls` on dotnet (real, phase 3.3)
//!
//! `startListenerTls` now terminates TLS for real on `--target dotnet` via
//! `Std.TcpHost.hostPrepareServerTls` / `hostUpgradeServerTlsPrepared`
//! (server identity + `minVersion` + ALPN + callback-free mTLS). The TLS
//! state is built once per listener, and each handshake runs on its
//! connection's own task under a handshake timeout, never on the accept loop
//! (#7268). The former phase-2 typed
//! `NotSupportedOnTarget` stub is gone. A mutual-TLS misconfiguration
//! (`requireClientCert` with no `clientCa`) is rejected up front with
//! `Err(InvalidConfig(...))` — the same security guard `Std.TcpHost`
//! enforces per-accept (#6042) — rather than binding a listener that would
//! reject every connection. Per-connection TLS handshake failures are handled
//! on the connection's task (the connection is dropped; the server keeps
//! serving), never fatal to the listener.
//!
//! ## h2/ALPN end-to-end (phase 4.4, issue #5889)
//!
//! `Std.TcpHost` now advertises `h2` ahead of `http/1.1` in the server's ALPN
//! list, so a TLS peer that offers HTTP/2 negotiates it (TLS-only — no h2c,
//! D128 decision 7). On each accepted connection the server selects the
//! protocol on `hostAlpn`: `"h2"` drives the pure-Lyric `Std.HttpEngine.H2Conn`
//! connection/stream FSM (#5888); `"http/1.1"` (or a plain / no-ALPN
//! connection) keeps the HTTP/1.1 `Std.HttpEngine.Connection` path. Both feed
//! the SAME pull surface (`nextContext` / `respond*` / chunked helpers): an h2
//! request stream is dispatched as an ordinary `HttpContext` and its response
//! is serialized back through the H2Conn send path (HEADERS + flow-controlled
//! DATA frames), so consumers (`lyric-web`, `examples`) serve h2 with no source
//! change. Request bodies are capped at the same `EngineLimits.maxBodyBytes` the
//! HTTP/1.1 path enforces: a stream whose accumulated DATA would exceed the cap
//! is answered `413` and never dispatched, and further DATA on it is dropped
//! (never buffered past the cap), so a hostile client cannot exhaust memory. The
//! rejection is terminal (`H2ConnState.rejectedStreams`, #6144/#6145) and its
//! bookkeeping is bounded (`pruneRejectedStreams`, #6566): a client that opens
//! many streams, gets each `413`-rejected, and then abandons every one (never
//! closing its own side) cannot grow that bookkeeping without bound.
//! Received-window credit is returned via `WINDOW_UPDATE` as DATA is consumed, so
//! a large legal body flows past the initial 64 KiB window. If the response
//! headers cannot be HPACK-encoded, the stream is reset with `RST_STREAM`
//! (`INTERNAL_ERROR`) rather than left hanging.
//!
//! ### h2 send scheduler (#6107)
//!
//! Each h2 connection has three parties, and the FSM state (HPACK encoder, flow
//! windows, stream table) has exactly one owner, the **connection task**:
//!
//!   * a **reader task** that only moves socket bytes into an inbound queue
//!     (bounded by `h2InboundCredits`) and signals the connection task;
//!   * **handlers** (the puller side) that never touch the wire for h2: a
//!     `respond*` call publishes the whole response, `beginChunkedResponse`
//!     publishes the head, `streamWriteChunk` queues a chunk (blocking on a
//!     per-stream credit of `h2StreamChunkCredits` chunks, which is the
//!     backpressure against a slow peer) and `endChunkedResponse` ends the
//!     stream, each followed by a wake signal;
//!   * the **connection task**, which blocks on that one signal and then runs a
//!     scheduling cycle: feed inbound bytes to the FSM, dispatch any completed
//!     request without waiting for its response, and write at most one frame
//!     per in-flight stream per pass (HEADERS first, then DATA bounded by the
//!     connection and stream send windows), repeating until every stream is
//!     idle or blocked on the peer's window. A peer `WINDOW_UPDATE` arrives as
//!     input and the next cycle resumes the blocked streams.
//!
//! So a slow handler on one stream no longer delays the others, DATA frames of
//! concurrent streams interleave, a response of any size is delivered as the
//! peer grants window (no bounded pump that gives up), and chunked responses
//! reach the wire per chunk. A stream the peer resets, or a connection that
//! closes, aborts the response: a handler blocked on credit wakes and its next
//! `streamWriteChunk` returns `Err`.
@axiom("System.Threading.Tasks.Task.Run, System.Collections.Concurrent.ConcurrentQueue, and System.Threading.SemaphoreSlim operations conform to their documented .NET contracts")
@io
package Std.HttpServer

import Std.Core
import Std.Collections
import Std.Char
import Std.Encoding
import Std.Tls
import Std.HttpEngine
// Aliased: `Std.HttpEngine.H2Conn` and `Std.HttpEngine` both export `feed` and
// `isFailed` (over `H2Connection` vs the HTTP/1.1 `Connection`). A bare call is
// ambiguous in the shared stdlib bundle — the MSIL codegen's bundle-global,
// package-unscoped name table binds it to whichever registered first (the
// HTTP/1.1 one), so a bare `feed`/`isFailed` on an `H2Connection` mis-binds and
// faults at runtime (#5903 class). Qualifying the h2-path calls `H2.feed` /
// `H2.isFailed` binds them unambiguously; the h1-path bare `feed` then resolves
// to `Std.HttpEngine` (no longer ambiguous, since H2Conn is only reachable via
// the alias). Every other H2Conn name used here is unique, so it stays bare.
import Std.HttpEngine.H2Conn as H2
// For the `H2InternalError` error code passed to `H2.sendRstStream` when an h2
// response cannot be encoded. H2Frame shares no `feed`/`isFailed` name with
// `Std.HttpEngine`, so it needs no alias.
import Std.HttpEngine.H2Frame
import Std.TcpHost
import Std.Environment as Env
import Std.Parse
import Std.String
import Std.Time

// =====================================================================
// Concurrency externs (BCL threading — the only externs in this file).
// `Task.Run(Action)` gives a background OS thread (Lyric `spawn` is
// degenerate-synchronous on this target). The blocking hand-off queue is a
// `ConcurrentQueue<T>` (unblocked enqueue/dequeue) paired with a
// `SemaphoreSlim` counting available items — chosen over `BlockingCollection`
// for two reasons that matter to the self-hosted MSIL emitter: (1) every
// member used here has a *unique arity*, so metadata overload resolution is
// unambiguous (`BlockingCollection.TryTake` has two two-argument overloads —
// `out T, int` vs `out T, TimeSpan` — that arity-only selection cannot
// distinguish, W0008); and (2) the dequeue is `ConcurrentQueue.TryDequeue(out
// T)`, an `out`-parameter form — a generic-*return* `Take(): T` mis-handles a
// value-type record with a reference-typed field (the returned copy loses the
// field's object identity), which silently broke the per-request `done`
// hand-off. `ConcurrentQueue` + `cqTryDequeue` is the same idiom `lyric-mq`'s
// kernel already uses.
// =====================================================================
extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

// Each accepted connection is served on a `Task.Run` (threadpool) thread that
// blocks in `hostRead` for the connection's lifetime — the thread-per-connection
// model (docs/61 §6.2). HTTP/2 connections are *persistent*: a client keeps one
// open and multiplexes many streams over it, so its server task blocks on a
// threadpool thread until the client disconnects. Under high fan-out (or a test
// that opens several h2 servers in one process without closing the client's
// pooled connections) enough blocking threads accumulate to starve the pool the
// client's own async continuations and the puller loop need — a classic
// blocking-I/O starvation deadlock. Raising the pool's minimum thread count so
// on-demand threads are created without the growth throttle keeps the pool from
// starving. (A fully async transport would remove the per-connection blocking
// threads entirely; an h2 connection holds two, its reader and its connection
// task.)
extern type ThreadPool = "System.Threading.ThreadPool"

@externStatic
@externTarget("System.Threading.ThreadPool.SetMinThreads")
func setMinThreads(workerThreads: in Int, completionPortThreads: in Int): Bool = ()

// The minimum threadpool size the server requests once on startup. Comfortably
// covers a large number of concurrently-blocked connection tasks plus the
// puller and client async machinery, without eagerly allocating them (threads
// are still created only on demand — this only raises the no-throttle ceiling).
func ensureServerThreadCapacity(): Unit {
  val _ = setMinThreads(200, 200);
  ()
}

extern type ConcurrentQueue[T] = "System.Collections.Concurrent.ConcurrentQueue`1"

@externTarget("System.Collections.Concurrent.ConcurrentQueue`1..ctor")
func newConcurrentQueue[T](): ConcurrentQueue[T] = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentQueue`1.Enqueue")
func cqEnqueue[T](q: in ConcurrentQueue[T], item: in T): Unit = ()

// `TryDequeue(out T)` is `ConcurrentQueue<T>`'s single one-argument dequeue —
// unambiguous by arity, and its `out` form preserves a value-type record's
// reference-typed fields (unlike a generic return).
@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentQueue`1.TryDequeue")
func cqTryDequeue[T](q: in ConcurrentQueue[T], result: out T): Bool = ()

// `SemaphoreSlim` is the availability signal: one `Release()` per enqueued
// item, one blocking `Wait()` per dequeue. All three members have unique arity
// (ctor takes one `int` initialCount; `Wait()` / `Release()` take none).
extern type Semaphore = "System.Threading.SemaphoreSlim"

@externTarget("System.Threading.SemaphoreSlim..ctor")
func newSemaphore(initialCount: in Int): Semaphore = ()

@externInstance
@externTarget("System.Threading.SemaphoreSlim.Wait")
func semWait(s: in Semaphore): Unit = ()

@externInstance
@externTarget("System.Threading.SemaphoreSlim.Release")
func semRelease(s: in Semaphore): Int = ()

// Bounds the number of connections served concurrently (#6071 hardening): the
// accept loop spawns one `Task.Run` thread per accepted connection with no
// upper bound, so a burst of many simultaneously-open connections (malicious
// or otherwise) could exhaust the .NET threadpool/OS thread or handle limits.
// A counting semaphore gates `taskRun` in `onAccepted`: the accept loop
// blocks (backpressure — new connections queue in the OS listen backlog
// rather than spawning unbounded background tasks) once this many
// connections are already in flight, and each connection task releases its
// permit when it finishes. 1000 comfortably covers ordinary production load
// while still bounding worst-case thread/handle usage. Operators can override
// it per deployment (without a rebuild) via the `LYRIC_HTTP_MAX_CONNECTIONS`
// environment variable — see `resolveMaxConcurrentConnections`.
val maxConcurrentConnectionsDefault: Int = 1000

// Resolve the concurrent-connection cap: honour `LYRIC_HTTP_MAX_CONNECTIONS`
// when it is set to a positive integer, otherwise fall back to
// `maxConcurrentConnectionsDefault`. A missing, non-numeric, or < 1 value
// falls back rather than failing — an unbounded (0/negative) cap would defeat
// the #6071 backpressure guarantee. Read once per listener at start; a cap of
// 1 is the seam the backpressure regression test uses. Public so a caller can
// query the effective cap (and so the resolution logic is directly testable).
pub func resolveMaxConcurrentConnections(): Int {
  match Env.getVar("LYRIC_HTTP_MAX_CONNECTIONS") {
    case Ok(raw) -> {
      match tryParseInt(raw) {
        case Ok(n) -> if n >= 1 { n } else { maxConcurrentConnectionsDefault }
        case Err(_) -> maxConcurrentConnectionsDefault
      }
    }
    case Err(_) -> maxConcurrentConnectionsDefault
  }
}

// Connection timeouts (#7268). A TLS handshake runs on the connection's own
// task, never the accept loop, and each of its blocking socket operations is
// bounded by `tlsHandshakeTimeoutMsDefault` (the same 10 s default Kestrel
// uses), so a peer that connects and never sends a ClientHello is dropped
// instead of pinning a connection permit. Once a connection is established,
// every blocking read and write is bounded by `connectionIdleTimeoutMsDefault`
// of inactivity, which closes idle keep-alive connections and peers that stop
// reading or sending mid-request. A handler that takes longer than this to
// respond is unaffected: the connection task waits on the handler, not on the
// socket, while a request is in flight. Both are per-deployment overridable
// through `LYRIC_HTTPS_HANDSHAKE_TIMEOUT_MS` / `LYRIC_HTTP_IDLE_TIMEOUT_MS`.
val tlsHandshakeTimeoutMsDefault: Int = 10000

val connectionIdleTimeoutMsDefault: Int = 120000

// How often the h2 drain watchdog checks whether its connection has ended.
val h2DrainWatchSliceMs: Int = 100

// The largest timeout either override accepts (one day, the same bound the
// native twin enforces); anything larger falls back to the default.
val maxTimeoutMs: Int = 86400000

// An integer in 1..`maxTimeoutMs` from `name`, otherwise `fallback`. A
// missing, non-numeric, or < 1 value falls back: a zero or negative timeout
// would silently disable the protection this setting exists for.
func positiveIntFromEnv(name: in String, fallback: in Int): Int {
  match Env.getVar(name) {
    case Ok(raw) -> match tryParseInt(raw) {
      case Ok(n) -> if n >= 1 and n <= maxTimeoutMs { n } else { fallback }
      case Err(_) -> fallback
    }
    case Err(_) -> fallback
  }
}

/// The TLS handshake timeout in milliseconds a listener applies: the
/// `LYRIC_HTTPS_HANDSHAKE_TIMEOUT_MS` environment variable when it is an
/// integer in 1..86400000 (one day), otherwise 10000. Read once per listener at start.
pub func resolveTlsHandshakeTimeoutMs(): Int {
  positiveIntFromEnv("LYRIC_HTTPS_HANDSHAKE_TIMEOUT_MS", tlsHandshakeTimeoutMsDefault)
}

/// The connection inactivity timeout in milliseconds a listener applies to
/// every blocking read and write: the `LYRIC_HTTP_IDLE_TIMEOUT_MS`
/// environment variable when it is an integer in 1..86400000 (one day),
/// otherwise 120000.
/// Read once per listener at start.
pub func resolveConnectionIdleTimeoutMs(): Int {
  positiveIntFromEnv("LYRIC_HTTP_IDLE_TIMEOUT_MS", connectionIdleTimeoutMsDefault)
}

// =====================================================================
// Public types.
// =====================================================================
/// Failure returned by `startListenerTls`. `InvalidConfig` reports a mutual-TLS
/// misconfiguration (`requireClientCert` without a `clientCa` to pin trust to)
/// caught before the listener binds. `NotSupportedOnTarget` is retained for
/// API/type stability across targets but is never constructed on `--target
/// dotnet` now that server TLS is real here.
pub union TlsListenError {
  case NotSupportedOnTarget(message: String)
  case InvalidConfig(message: String)
}

/// Human-readable message for a `TlsListenError`.
@pure
pub func TlsListenError.message(e: in TlsListenError): String {
  match e {
    case NotSupportedOnTarget(m) -> m
    case InvalidConfig(m) -> m
  }
}

/// A running server. Holds the bound transport listener, the queue of ready
/// request contexts the background accept loop feeds and `nextContext` drains
/// (with `available` counting queued items), and the accept-loop task handle
/// (kept alive so the loop is not collected). Opaque to consumers: observe it
/// only through `nextContext` / `stopListener`.
pub record HttpListener {
  transport: Listener
  queue: ConcurrentQueue[HttpContext]
  available: Semaphore
  acceptTask: Task
}

/// One fully-parsed request plus the machinery to respond to it. `conn` is the
/// live transport connection (owned by the connection task; the puller writes
/// the response to it during the response phase); `done` is the one-shot
/// semaphore a respond helper releases so the connection task learns the
/// response is written and may read the next request. `keepAlive` is the
/// engine's keep-alive decision for this exchange. Treat the fields as private
/// — observe a context only through the `request*` accessors and construct a
/// response only through the `respond*` / chunked helpers.
pub record HttpContext {
  conn: Conn
  method: String
  target: String
  version: HttpVersion
  headers: List[HeaderField]
  body: slice[Byte]
  keepAlive: Bool
  done: Semaphore
  // `Some` for a request served over HTTP/2: the response is delivered into
  // this exchange mailbox by the `respond*` / chunked helpers (on the puller
  // thread) and serialized back through the H2Conn send path by the connection
  // task. `None` for HTTP/1.1, where `respond*` writes the wire response
  // directly. See the module header's h2 section.
  h2: Option[H2Exchange]
  // Shared with the connection task that produced this context; set by
  // `takeConnection` so that task stops serving the connection without
  // closing it.
  handoff: ConnHandoff
  // True when the client sent bytes past this request before any response
  // (pipelining). `takeConnection` refuses such a request: the engine has
  // already consumed those bytes, so they could not reach the new owner.
  trailingInput: Bool
}

// Per-connection ownership flag. `taken` flips once, on the puller thread,
// before it releases the context's `done` semaphore; the connection task reads
// it after `semWait(done)`, so the semaphore orders the write before the read.
pub ref record ConnHandoff {
  var taken: Bool = false
}

// Per-connection state shared between the connection task and the handler
// threads that answer its streams. `outbox` carries a notice per response
// change (headers ready, chunk queued, body ended) and `wake` is the one signal
// the connection task blocks on, shared with the reader task so the task wakes
// for input or for handler output alike. `closed` is set once at teardown.
pub ref record H2Link {
  var closed: Bool = false
  outbox: ConcurrentQueue[H2Notice]
  wake: Semaphore
}

pub record H2Notice {
  streamId: Int
}

pub record H2Chunk {
  bytes: slice[Byte]
}

record H2Inbound {
  bytes: slice[Byte]
}

// The response mailbox for one HTTP/2 request stream. The handler thread fills
// `status` / `contentType` / `extra` and queues body slices on `chunks`, then
// publishes the change with `h2Notify`; the owning connection task alone
// HPACK-encodes the headers and frames the body as flow-controlled DATA on
// `streamId`, interleaved with the other streams. Kept free of any
// `H2Connection` reference so the FSM state stays touched only by the
// connection task (no cross-thread mutation of the shared hpack encoder / flow
// windows). A buffered response (`respond*`) sets `chunked = false` and
// `bodyLength` and ends in one step; a chunked response sets `chunked = true`
// at `beginChunkedResponse` and queues chunks until `endChunkedResponse`.
// `credit` bounds how many chunks may be queued ahead of the connection task.
// `aborted` is set when the peer resets the stream or the connection closes.
pub ref record H2Exchange {
  streamId: Int
  link: H2Link
  chunks: ConcurrentQueue[H2Chunk]
  credit: Semaphore
  var status: Int
  var contentType: String
  extra: Map[String, String]
  var bodyLength: Int
  var chunked: Bool
  var started: Bool
  var ended: Bool
  var aborted: Bool
}

// The connection task's send state for a stream whose response has begun:
// `cur` is the slice being framed (from `curOff`), `next` a slice already taken
// off the queue by the END_STREAM look-ahead.
ref record H2Out {
  exchange: H2Exchange
  var headersSent: Bool
  var hasCur: Bool
  var cur: slice[Byte]
  var curOff: Int
  var hasNext: Bool
  var next: slice[Byte]
  var finished: Bool
}

func addH2BodyChunk(exchange: in H2Exchange, bytes: in slice[Byte]): Unit {
  if bytes.length > 0 {
    cqEnqueue(exchange.chunks, H2Chunk(bytes = bytes))
    exchange.bodyLength = exchange.bodyLength + bytes.length
  }
}

// Per-stream request accumulation on the connection task: the HPACK-decoded
// request `headers` and the DATA-frame `body` gathered until END_STREAM, at
// which point the stream is dispatched as an `HttpContext`.
record H2ReqAccum {
  var headers: List[HeaderField]
  body: List[Byte]
  var haveHeaders: Bool
}

// The request line + non-pseudo headers extracted from an h2 header block.
record H2RequestLine {
  method: String
  target: String
  headers: List[HeaderField]
}

// Mutable per-connection h2 driver state, threaded (by reference) through the
// event loop and the response send path. `h2` is mutated in place by `feed`
// (which returns the same connection object), so its identity is stable across
// the connection's lifetime.
ref record H2ConnState {
  conn: Conn
  var h2: H2.H2Connection
  accums: Map[Int, H2ReqAccum]
  queue: ConcurrentQueue[HttpContext]
  available: Semaphore
  var open: Bool
  // The peer half-closed (the reader hit end-of-input): nothing more will be
  // read, but dispatched exchanges keep running and their responses are still
  // written. The connection closes once `exchanges` is empty, or when
  // `drainExpired` (set by the drain watchdog after the idle timeout) says a
  // handler never answered.
  var draining: Bool
  var drainExpired: Bool
  link: H2Link
  // Socket bytes the reader task has read, awaiting the connection task, and
  // the credit that bounds how far the reader may run ahead.
  inbound: ConcurrentQueue[H2Inbound]
  inCredit: Semaphore
  // Responses in flight, keyed by stream id; touched only by the connection
  // task. `exchanges` holds every dispatched stream's mailbox, `outs` those
  // whose response has begun, `order` the latter in arrival order.
  exchanges: Map[Int, H2Exchange]
  outs: Map[Int, H2Out]
  var order: List[Int]
  // The same `EngineLimits` the HTTP/1.1 path enforces (`maxBodyBytes` in
  // particular): an h2 request body is capped identically, at parity.
  limits: EngineLimits
  // Stream ids that have been *terminally rejected* for exceeding
  // `maxBodyBytes` (a `413` was sent, the request never dispatched). Consulted on
  // every subsequent frame — DATA *and* a trailer HEADERS block — so a rejected
  // stream can never re-dispatch the request or trip a protocol violation
  // (#6144). The stream's `H2ReqAccum` is dropped when it is rejected (freeing
  // its buffered headers/body), so the accumulator map only ever holds
  // in-progress non-rejected streams (#6145); this marker set is pruned when the
  // stream reaches END_STREAM or is reset. A rejected stream a client abandons
  // (never sends END_STREAM or RST_STREAM) keeps only this tiny id marker, but
  // the underlying stream also stays FSM-active (`H2SHalfClosedLocal` — our own
  // `413` closed only the server's send side) for as long as the client leaves
  // it dangling, so it counts against `SETTINGS_MAX_CONCURRENT_STREAMS` the
  // whole time; growth is soft-bounded by that admission-control ceiling, not
  // literally unbounded the way `H2Connection.streams` was before #6064. That
  // coupling to a setting this marker set does not own is fragile, not a
  // designed bound, so `pruneRejectedStreams` (#6566) still actively reclaims
  // an old-enough abandoned entry: see its doc comment for the mechanism and
  // safety argument (id-distance pruning here cannot just drop the marker the
  // way `pruneClosedStreams` does — the underlying stream can still be
  // FSM-live — so it forces an RST_STREAM first).
  rejectedStreams: Map[Int, Bool]
}

/// An open chunked (`Transfer-Encoding: chunked`) response. Carries the
/// connection the caller writes chunks to via `streamWriteChunk` and the
/// `done` semaphore `endChunkedResponse` releases to complete the exchange.
pub record HttpChunkedStream {
  conn: Conn
  done: Semaphore
  // `Some` for a chunked response over HTTP/2: each `streamWriteChunk` queues
  // the chunk for the connection task, which frames it as DATA as soon as the
  // peer's flow-control window allows, and `endChunkedResponse` ends the
  // stream. `None` for HTTP/1.1, where chunks are written to the wire
  // incrementally.
  h2: Option[H2Exchange]
}

// =====================================================================
// Prefix parsing (pure Lyric) — accepts the "http://host:port/path" shape the
// old `HttpListener` prefixes used, mirroring the JVM twin. `https://` has no
// room for a TLS config and is rejected loudly (use `startListenerTls`).
// =====================================================================
func isDigit(c: in Char): Bool {
  val cp = toInt(c)
  cp >= 48 and cp <= 57
}

func parsePort(text: in String, prefix: in String): Int {
  if text.length == 0 {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': empty port")
  }
  var value = 0
  var i = 0
  while i < text.length {
    val c = charAtOrReplacement(text, i)
    if not isDigit(c) {
      panic("Std.HttpServer: invalid listener prefix '" + prefix + "': non-numeric port '" + text + "'")
    }
    value = value * 10 + (toInt(c) - 48)
    i = i + 1
  }
  if value < 1 or value > 65535 {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': port out of range")
  }
  value
}

record ParsedPrefix {
  bindHost: String
  port: Int
}

func parsePrefix(prefix: in String): ParsedPrefix {
  if prefix.startsWith("https://") {
    panic(
      "Std.HttpServer: startListener's single-string prefix has no room for a TLS " +
        "config; use startListenerTls(host, port, tls) for HTTPS listeners"
    )
  }
  if not prefix.startsWith("http://") {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': expected \"http://host:port/\"")
  }
  val rest = prefix.substring(7, prefix.length - 7)
  var slashAt = 0 - 1
  var i = 0
  while i < rest.length and slashAt < 0 {
    if charAtOrReplacement(rest, i) == '/' {
      slashAt = i
    }
    i = i + 1
  }
  val hostPort = if slashAt >= 0 { rest.substring(0, slashAt) } else { rest }
  var colonAt = 0 - 1
  var j = 0
  while j < hostPort.length {
    if charAtOrReplacement(hostPort, j) == ':' {
      colonAt = j
    }
    j = j + 1
  }
  val bindHost = if colonAt >= 0 { hostPort.substring(0, colonAt) } else { hostPort }
  val port = if colonAt >= 0 {
    parsePort(hostPort.substring(colonAt + 1, hostPort.length - colonAt - 1), prefix)
  } else {
    80
  }
  if bindHost.length == 0 {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': empty host")
  }
  ParsedPrefix(bindHost = bindHost, port = port)
}

// `Std.TcpHost.hostListen` binds an IP literal, not a DNS name. Map the common
// non-literal binds the old prefix convention used: "*"/"+" and "0.0.0.0" bind
// the IPv4 wildcard; "localhost" binds loopback. Any other value is passed
// through as an IP literal (a real hostname would fail `IPAddress.Parse`
// loudly — servers bind to addresses, not names).
func resolveBindHost(host: in String): String {
  if host == "*" or host == "+" {
    "0.0.0.0"
  } else if host == "localhost" {
    "127.0.0.1"
  } else {
    host
  }
}

// =====================================================================
// Response status reason phrases. An empty reason is RFC 9112 §4-legal (and
// `Std.HttpEngine.serializeResponseHead` accepts it), so an unlisted code is
// serialized with a blank reason rather than a fabricated one.
// =====================================================================
func reasonForStatus(status: in Int): String {
  if status == 100 {
    "Continue"
  } else if status == 200 {
    "OK"
  } else if status == 201 {
    "Created"
  } else if status == 202 {
    "Accepted"
  } else if status == 204 {
    "No Content"
  } else if status == 301 {
    "Moved Permanently"
  } else if status == 302 {
    "Found"
  } else if status == 304 {
    "Not Modified"
  } else if status == 400 {
    "Bad Request"
  } else if status == 401 {
    "Unauthorized"
  } else if status == 403 {
    "Forbidden"
  } else if status == 404 {
    "Not Found"
  } else if status == 405 {
    "Method Not Allowed"
  } else if status == 409 {
    "Conflict"
  } else if status == 413 {
    "Content Too Large"
  } else if status == 414 {
    "URI Too Long"
  } else if status == 431 {
    "Request Header Fields Too Large"
  } else if status == 500 {
    "Internal Server Error"
  } else if status == 501 {
    "Not Implemented"
  } else if status == 503 {
    "Service Unavailable"
  } else if status == 505 {
    "HTTP Version Not Supported"
  } else {
    ""
  }
}

// =====================================================================
// Per-connection request reader (runs on the connection task).
// =====================================================================
// Outcome of parsing one request off a keep-alive connection. Distinctive case
// names (never a bare `Close`/`Request`) keep them collision-free in the
// bundle-global codegen name table (#5903).
union ReqOutcome {
  case RoClose
  case RoRequest(method: String, target: String, version: HttpVersion, headers: List[HeaderField], body: slice[Byte], keepAlive: Bool, trailingInput: Bool)
  case RoProtocolFail(status: Int)
}

func emptyBytes(): slice[Byte] {
  val e: slice[Byte] = []
  e
}

// One `List<byte>.AddRange` per chunk (a single array copy), not an `Add`
// per byte (#7269).
@externInstance
@externTarget("System.Collections.Generic.List`1.AddRange")
func listAddRangeBytes(acc: in List[Byte], bytes: in slice[Byte]): Unit = ()

func appendBytes(acc: in List[Byte], bytes: in slice[Byte]): Unit {
  listAddRangeBytes(acc, bytes)
}

// Write an interim `100 Continue` head (no body) when the request carried
// `Expect: 100-continue`; the client then sends the body.
func writeInterimContinue(conn: in Conn, version: in HttpVersion): Unit {
  val noHeaders: List[HeaderField] = newList()
  val head = serializeResponseHead(version, 100, reasonForStatus(100), noHeaders)
  val _ = hostWrite(conn, head);
  ()
}

// Read and parse exactly one request off `conn`, advancing the engine FSM.
// Drains any already-buffered (pipelined) bytes before issuing a fresh read,
// so a keep-alive connection with a second request already in the buffer does
// not block waiting for more network input.
func readOneRequest(conn: in Conn, engineConn: inout Connection): ReqOutcome {
  var method = ""
  var target = ""
  var version: HttpVersion = Http1_1
  var headers: List[HeaderField] = newList()
  val body: List[Byte] = newList()
  var first = true
  while true {
    // Statement form (not `val = if ... else match ...`): the tail-position
    // `match`-inside-an-`else` shape is both harder on some parsers and against
    // this codebase's match-factoring style (see http_engine.l's #5936 notes).
    var events: List[HttpEvent] = newList()
    if first {
      first = false
      val fr0 = Std.HttpEngine.feed(engineConn, emptyBytes())
      engineConn = fr0.conn
      events = fr0.events
    } else {
      match hostRead(conn, 65536) {
        case Err(_) -> return RoClose
        case Ok(bytes) -> {
          if bytes.length == 0 {
            return RoClose
          }
          val fr1 = Std.HttpEngine.feed(engineConn, bytes)
          engineConn = fr1.conn
          events = fr1.events
        }
      }
    }
    var i = 0
    while i < events.count {
      val ev = events[i]
      match ev {
        case NeedMore -> ()
        case RequestHead(m, t, v, hs) -> {
          method = m
          target = t
          version = v
          headers = hs
        }
        case ExpectContinue -> writeInterimContinue(conn, version)
        case BodyChunk(b) -> appendBytes(body, b)
        case RequestComplete -> {
          return RoRequest(
            method = method,
            target = target,
            version = version,
            headers = headers,
            body = body.toArray(),
            keepAlive = not shouldClose(engineConn),
            trailingInput = i + 1 < events.count or hasBufferedInput(engineConn)
          )
        }
        case ProtocolError(kind, _) -> return RoProtocolFail(status = protocolErrorStatus(kind))
      }
      i = i + 1
    }
  }
  RoClose
}

// Write a minimal bodyless error response (used for a `ProtocolError` before a
// context is ever handed to the puller) and always close the connection.
func writeErrorResponse(conn: in Conn, status: in Int): Unit {
  val headers: List[HeaderField] = newList()
  headers.add(HeaderField(name = "Content-Length", value = "0"))
  headers.add(HeaderField(name = "Connection", value = "close"))
  val head = serializeResponseHead(Http1_1, status, reasonForStatus(status), headers)
  val _ = hostWrite(conn, head);
  ()
}

// The per-connection loop: parse a request, hand a ready context to the puller,
// block until the puller responds, then either read the next request (keep
// alive) or close.
func processConnection(
  conn: in Conn,
  queue: in ConcurrentQueue[HttpContext],
  available: in Semaphore,
  limits: in EngineLimits,
  connLimit: in Semaphore,
): Unit {
  // Guarantee the socket is closed and this connection's concurrency-limit
  // permit (#6071) is released even if request handling throws — a broken
  // socket can throw from readOneRequest/writeErrorResponse. Because this
  // runs via fire-and-forget `taskRun`, a leaked permit is never recovered
  // and would eventually wedge the accept loop on `semWait(connLimit)` (#6221).
  // After `takeConnection` the socket belongs to the caller, so it is not
  // closed here; the permit is still released, since the connection no
  // longer counts against the HTTP server's cap.
  val handoff = ConnHandoff()
  defer {
    if not handoff.taken {
      hostClose(conn)
    }
    val _ = semRelease(connLimit)
  }
  var engineConn = newConnection(limits)
  var open = true
  while open {
    val outcome = readOneRequest(conn, engineConn)
    match outcome {
      case RoClose -> {
        open = false
      }
      case RoProtocolFail(status) -> {
        writeErrorResponse(conn, status)
        open = false
      }
      case RoRequest(method, target, version, headers, body, keepAlive, trailingInput) -> {
        val done: Semaphore = newSemaphore(0)
        val noH2: Option[H2Exchange] = None
        val ctx = HttpContext(
          conn = conn,
          method = method,
          target = target,
          version = version,
          headers = headers,
          body = body,
          keepAlive = keepAlive,
          done = done,
          h2 = noH2,
          handoff = handoff,
          trailingInput = trailingInput
        )
        cqEnqueue(queue, ctx)
        val _ = semRelease(available)
        // Block until a respond helper releases `done`. Keep-alive is the
        // engine's decision (`keepAlive`); a failed response write is not
        // signalled here — the next `readOneRequest` hits the broken socket and
        // returns `RoClose`, closing the connection one iteration later.
        semWait(done)
        if not keepAlive or handoff.taken {
          open = false
        }
      }
    }
  };
  // `hostClose(conn)` + `semRelease(connLimit)` run via the `defer` above so
  // they still fire if the loop body throws (#6221).
  ()
}

// Handle one plain accept result: on success apply the idle timeout, spawn a
// per-connection task and keep the loop running; on a stopped listener
// (`AcceptFailed`/`BindFailed`) end the loop. Returns whether the accept loop
// should keep running.
func onAccepted(
  accepted: in Result[Conn, TcpError],
  queue: in ConcurrentQueue[HttpContext],
  available: in Semaphore,
  limits: in EngineLimits,
  connLimit: in Semaphore,
  idleTimeoutMs: in Int,
): Bool {
  match accepted {
    case Ok(conn) -> {
      hostSetIoTimeout(conn, idleTimeoutMs)
      // Bound the number of connections served concurrently (#6071): acquire
      // a permit before spawning the connection task, so the accept loop
      // itself blocks (backpressure) once the resolved cap
      // (`resolveMaxConcurrentConnections`) connections are already in flight,
      // rather than spawning an unbounded number of background tasks. The
      // connection task releases the permit when it finishes
      // (`processConnection`/`processH2Connection`).
      semWait(connLimit)
      // Select the protocol on the negotiated ALPN (docs/61 §6.4): a TLS peer
      // that negotiated `h2` drives the HTTP/2 FSM; everything else (plain
      // connection, `http/1.1`, or no ALPN) speaks HTTP/1.1.
      if hostAlpn(conn) == "h2" {
        val _ = taskRun({ -> processH2Connection(conn, queue, available, limits, connLimit) })
      } else {
        val _ = taskRun({ -> processConnection(conn, queue, available, limits, connLimit) })
      }
      true
    }
    case Err(e) -> acceptLoopContinues(e)
  }
}

// Whether an accept failure leaves the loop running: a stopped listener
// (`AcceptFailed`/`BindFailed`) ends it; anything else is per-connection.
func acceptLoopContinues(e: in TcpError): Bool {
  match e {
    case AcceptFailed(_) -> false
    case BindFailed(_) -> false
    case _ -> true
  }
}

// The TLS connection task body (#7268): run the handshake here, on the
// connection's own task, so a slow or silent peer never blocks the accept
// loop, then serve the connection on this same task with the protocol its
// ALPN selected. A failed handshake closes the socket and releases the
// connection permit the accept loop took.
func serveTlsConnection(
  plain: in Conn,
  tls: in ServerTls,
  queue: in ConcurrentQueue[HttpContext],
  available: in Semaphore,
  limits: in EngineLimits,
  connLimit: in Semaphore,
  handshakeTimeoutMs: in Int,
  idleTimeoutMs: in Int,
): Unit {
  match hostUpgradeServerTlsPrepared(plain, tls, handshakeTimeoutMs) {
    case Err(_) -> {
      hostClose(plain)
      val _ = semRelease(connLimit)
    }
    case Ok(conn) -> {
      hostSetIoTimeout(conn, idleTimeoutMs)
      if hostAlpn(conn) == "h2" {
        processH2Connection(conn, queue, available, limits, connLimit)
      } else {
        processConnection(conn, queue, available, limits, connLimit)
      }
    }
  }
}

// Plain (non-TLS) accept loop. Split from the TLS loop rather than branching on
// an `Option[TlsServerConfig]` parameter inside the loop: a cross-package
// `Option[TlsServerConfig]` argument threaded through the background-task
// closure degrades in the multi-package bundle build (the self-hosted MSIL
// emitter's #2494 generic-instantiation degradation), so the `match tls` there
// silently faulted and the accept loop never accepted. Two monomorphic loops
// carry no generic-over-extern-payload parameter and are unaffected.
func plainAcceptLoop(
  transport: in Listener,
  queue: in ConcurrentQueue[HttpContext],
  available: in Semaphore,
  limits: in EngineLimits,
  connLimit: in Semaphore,
): Unit {
  val idleTimeoutMs = resolveConnectionIdleTimeoutMs()
  var running = true
  while running {
    val accepted = hostAccept(transport)
    running = onAccepted(accepted, queue, available, limits, connLimit, idleTimeoutMs)
  }
}

// TLS accept loop. It only accepts the raw socket and takes a connection
// permit; the handshake itself runs on the connection's task
// (`serveTlsConnection`, #7268) against the `ServerTls` state the listener
// built once at start.
func tlsAcceptLoop(
  transport: in Listener,
  queue: in ConcurrentQueue[HttpContext],
  available: in Semaphore,
  tls: in ServerTls,
  limits: in EngineLimits,
  connLimit: in Semaphore,
): Unit {
  val handshakeTimeoutMs = resolveTlsHandshakeTimeoutMs()
  val idleTimeoutMs = resolveConnectionIdleTimeoutMs()
  var running = true
  while running {
    match hostAccept(transport) {
      case Ok(plain) -> {
        semWait(connLimit)
        val _ = taskRun(
          { ->
            serveTlsConnection(plain, tls, queue, available, limits, connLimit, handshakeTimeoutMs, idleTimeoutMs)
          }
        )
      }
      case Err(e) -> {
        running = acceptLoopContinues(e)
      }
    }
  }
}

// =====================================================================
// HTTP/2 connection driver (runs on the connection task).
//
// A single connection task owns all socket I/O and all `H2Conn` FSM feeding
// for one h2 connection, so the shared HPACK encoder / flow-control windows are
// never touched from two threads. A complete request stream is dispatched as an
// ordinary `HttpContext` onto the same pull queue the HTTP/1.1 path uses; the
// puller's `respond*` helper fills the stream's `H2Exchange` mailbox and
// releases `done`, then the connection task serializes the response back as
// HEADERS + flow-controlled DATA frames by the connection task's send
// scheduler, which interleaves concurrent streams (#6107, see the module header).
// =====================================================================
func minIntH2(a: in Int, b: in Int): Int {
  if a < b {
    a
  } else {
    b
  }
}

func asciiLower(s: in String): String {
  val sb = StringBuilder.new()
  var i = 0
  while i < s.length {
    val cp = codeUnitAt(s, i)
    if cp >= 65 and cp <= 90 {
      sb.appendChar(Std.Char.fromInt(cp + 32))
    } else {
      // Copied as a raw code unit: a surrogate half is not a `Char`.
      sb.append(s.substring(i, 1))
    }
    i = i + 1
  }
  sb.toString()
}

// RFC 9113 §8.2.2: connection-specific header fields are forbidden in HTTP/2.
// `content-type` / `content-length` are set explicitly by the sender, so they
// are also skipped when copying extra headers.
func isH2SkippedResponseHeader(lowerName: in String): Bool {
  lowerName == "connection" or lowerName == "keep-alive" or lowerName == "proxy-connection" or
    lowerName == "transfer-encoding" or
    lowerName == "upgrade" or
    lowerName == "content-length" or
    lowerName == "content-type"
}

func getOrCreateAccum(state: in H2ConnState, streamId: in Int): H2ReqAccum {
  match mapGet(state.accums, streamId) {
    case Some(a) -> a
    case None -> {
      val fresh = H2ReqAccum(headers = newList(), body = newList(), haveHeaders = false)
      state.accums.add(streamId, fresh)
      fresh
    }
  }
}

func removeAccum(state: in H2ConnState, streamId: in Int): Unit {
  val _ = state.accums.remove(streamId)
}

// Mark `streamId` as terminally rejected (over `maxBodyBytes`) and drop its
// accumulator so no buffered headers/body are retained (#6145). Subsequent
// frames on it are dropped by `isRejectedStream` (#6144).
func markRejectedStream(state: in H2ConnState, streamId: in Int): Unit {
  state.rejectedStreams.add(streamId, true)
  removeAccum(state, streamId)
}

func isRejectedStream(state: in H2ConnState, streamId: in Int): Bool {
  match mapGet(state.rejectedStreams, streamId) {
    case Some(_) -> true
    case None -> false
  }
}

// Prune the rejected-stream marker once the stream is fully closed (its
// END_STREAM seen, or a reset), so the marker set does not retain closed streams.
func forgetRejectedStream(state: in H2ConnState, streamId: in Int): Unit {
  val _ = state.rejectedStreams.remove(streamId)
}

// How many trailing client stream-id slots (each 2 apart, matching
// `H2.h2ClosedStreamRetentionWindow`'s id-distance shape) an abandoned
// rejected-stream marker is tolerated before `pruneRejectedStreams`
// actively reclaims it. Deliberately smaller than
// `H2.h2ClosedStreamRetentionWindow()` (200): unlike an `H2SClosed` FSM
// record, a lingering `rejectedStreams` marker's underlying stream is
// *never* naturally reclaimed on its own (see the `H2ConnState.rejectedStreams`
// doc comment) and stays FSM-active the whole time it lingers, so it is
// already soft-bounded well below this window by
// `SETTINGS_MAX_CONCURRENT_STREAMS` (128 by default,
// `h2DefaultServerSettings`) — this window only needs to be comfortably
// clear of any realistic single-request round trip, not to match #6064's
// generous "keep the terminal event observable" margin.
@pure
@experimental
pub func h2RejectedStreamRetentionWindow(): Int {
  64
}

// Pure id-distance test backing `pruneRejectedStreams`: is `streamId` more
// than `window` client stream-id slots behind `highWaterMark`? Exposed
// `pub` purely so the threshold arithmetic is independently unit-testable
// without a live connection (mirrors `H2Conn`'s own testable query-surface
// precedent, e.g. `h2ClosedStreamRetentionWindow`) — `pruneRejectedStreams`
// itself needs a live `H2ConnState` (real socket-backed) and so cannot be
// unit-tested directly.
@pure
@experimental
pub func h2RejectedStreamIsReclaimable(streamId: in Int, highWaterMark: in Int, window: in Int): Bool {
  streamId < highWaterMark - window * 2
}

// Actively reclaim `rejectedStreams` entries that have scrolled
// `h2RejectedStreamRetentionWindow()` slots behind the connection's current
// high-water mark (#6566).
//
// Safety argument (the equivalent of `pruneClosedStreams`'s "a lookup miss
// is never silently permitted" invariant, adapted to this layer): a
// `rejectedStreams[id]` marker, once old enough to be eligible here, always
// corresponds to a FSM stream still sitting at `H2SHalfClosedLocal` — the
// client never sent END_STREAM/RST_STREAM to close its own side (if it had,
// `forgetRejectedStream` would already have removed the marker at that
// event, well before this id-distance check could ever fire). Unlike a
// `pruneClosedStreams`-eligible `H2SClosed` record, that stream is NOT
// already closed at the FSM level, so simply dropping our marker (as
// `pruneClosedStreams` does for its own, already-dead records) would be
// unsafe: a later legitimate-looking DATA or trailer HEADERS on that same
// id would sail past `isRejectedStream`'s now-absent guard and get
// re-accumulated/dispatched — exactly what #6144/#6145 exist to prevent.
// So reclaiming here does not just forget the marker: it first issues a
// real `RST_STREAM` (RFC 9113 section 6.4's administrative-close idiom —
// the same mechanism `sendH2Reject413`'s own HPACK-encode-failure path
// already resets a stream with), which `H2.sendRstStream` applies to the
// FSM's own record, transitioning it to `H2SClosed`. From that point on the
// FSM itself rejects any further frame on the id before it can ever reach
// `onH2Data`/`onH2Headers` again — DATA gets a stream-level
// `reclaimAndStreamFail`, and a HEADERS reusing the id gets a connection
// `PROTOCOL_ERROR` (RFC 9113 section 5.1.1, #6562) — so forgetting our own
// marker at the same moment is provably safe, not merely convenient.
// `H2.sendRstStream` is itself a safe no-op (empty bytes, no mutation) if
// the FSM has no record for the id at all (already closed and reclaimed by
// `pruneClosedStreams`, or never existed), so this can never resurrect or
// mis-close an unrelated stream.
func pruneRejectedStreams(state: in H2ConnState): Unit {
  val window = h2RejectedStreamRetentionWindow()
  // Cheap escape hatch, mirroring `pruneClosedStreams`'s own: nothing to
  // reclaim until the marker count exceeds the window.
  if state.rejectedStreams.count <= window {
    return
  }
  val highWaterMark = H2.lastPeerStreamId(state.h2)
  val ids = mapKeys(state.rejectedStreams).toArray()
  var i = 0
  while i < ids.length {
    val id = ids[i]
    if h2RejectedStreamIsReclaimable(id, highWaterMark, window) {
      val rst = H2.sendRstStream(state.h2, id, H2Cancel)
      if rst.length > 0 {
        val _ = hostWrite(state.conn, rst);
        ()
      }
      forgetRejectedStream(state, id)
    }
    i = i + 1
  }
}

// Split an HPACK-decoded request header block into method / path / non-pseudo
// headers (RFC 9113 §8.3.1). Missing `:method` / `:path` default defensively
// (mirroring the HTTP/1.1 kernel's `requestMethod`/`requestPath` fallbacks);
// `:authority` is surfaced as a `host` header so Host-keyed consumers behave
// as they do over HTTP/1.1.
func extractH2Request(headers: in List[HeaderField]): H2RequestLine {
  var method = "GET"
  var target = "/"
  var authority = ""
  val regular: List[HeaderField] = newList()
  var i = 0
  while i < headers.count {
    val h = headers[i]
    if h.name == ":method" {
      method = h.value
    } else if h.name == ":path" {
      target = h.value
    } else if h.name == ":authority" {
      authority = h.value
    } else if h.name.startsWith(":") {
      // Any other pseudo-header (`:scheme`, or an unknown one): not a real
      // request header, drop it.
      ()
    } else {
      regular.add(h)
    }
    i = i + 1
  }
  if authority.length > 0 {
    regular.add(HeaderField(name = "host", value = authority))
  }
  H2RequestLine(method = method, target = target, headers = regular)
}

// Feed newly-read bytes into the connection FSM: advance the decoder, write any
// control frames it emitted (SETTINGS ACK, PING ACK, WINDOW_UPDATE reclaim,
// RST_STREAM, GOAWAY), and append every semantic event onto `work` for the
// caller's processing loop to drain (which is also how a flow-control pump
// surfaces a concurrently-opened stream — it is appended and processed after
// the in-flight response completes).
func h2Feed(state: in H2ConnState, bytes: in slice[Byte], work: in List[H2.H2Event]): Unit {
  if H2.isFailed(state.h2) {
    return
  }
  val fr = H2.feed(state.h2, bytes)
  state.h2 = fr.conn
  if fr.outbound.length > 0 {
    val _ = hostWrite(state.conn, fr.outbound);
    ()
  }
  var i = 0
  while i < fr.events.count {
    work.add(fr.events[i])
    i = i + 1
  }
}

// Copy caller-supplied response headers into the h2 header list: lowercase each
// name (RFC 9113 §8.2 requires lowercase field names), drop connection-specific
// and already-set content-* headers, and skip response-unsafe values.
func appendH2ExtraHeaders(headers: in List[HeaderField], extra: in Map[String, String]): Unit {
  val names = mapKeys(extra).toArray()
  var i = 0
  while i < names.length {
    val name = names[i]
    val lower = asciiLower(name)
    if lower.length > 0 and not isH2SkippedResponseHeader(lower) {
      match mapGet(extra, name) {
        case Some(value) -> {
          // Drop, rather than send, any field `encodeResponseHeaders`'
          // precondition would refuse (#7251): a hostile reflected header must
          // not take the connection down.
          if responseHeaderSafe(value) and H2.isH2ResponseFieldSafe(lower, value) {
            headers.add(HeaderField(name = lower, value = value))
          }
        }
        case None -> ()
      }
    }
    i = i + 1
  }
}

// Size of the per-stream chunk credit: how many chunks a handler may have
// queued (written but not yet taken by the connection task) on one stream
// before `streamWriteChunk` blocks. This is the backpressure that keeps a fast
// handler streaming to a slow peer from buffering without bound.
val h2StreamChunkCredits: Int = 32

// How many socket reads the reader task may have queued ahead of the
// connection task. Bounds the memory a peer can force by sending faster than
// the connection task processes; the peer's own flow control bounds request
// bodies, this bounds control-frame floods.
val h2InboundCredits: Int = 8

// Wake the connection task for `x`: its response state changed (headers ready,
// a chunk queued, or the body ended). The notice is enqueued before the wake
// signal so the woken task always finds it. If the connection has already torn
// down (checked after the enqueue, so a teardown that ran in between is seen),
// the exchange is aborted here so no handler ever blocks on a dead connection.
func h2Notify(x: in H2Exchange): Unit {
  cqEnqueue(x.link.outbox, H2Notice(streamId = x.streamId))
  val _ = semRelease(x.link.wake)
  if x.link.closed {
    h2Abort(x)
  }
}

// Mark a stream's response dead (peer reset it, or the connection closed) and
// wake a handler that may be blocked waiting for chunk credit; it observes
// `aborted` and returns an error instead of writing.
func h2Abort(x: in H2Exchange): Unit {
  x.aborted = true
  val _ = semRelease(x.credit)
  val _2 = semRelease(x.credit);
  ()
}

func h2ReleaseCredit(x: in H2Exchange): Unit {
  val _ = semRelease(x.credit);
  ()
}

// Forget a stream's server-side response state once its response has been fully
// framed (or its stream died).
func h2FinishStream(state: in H2ConnState, streamId: in Int): Unit {
  val _ = state.outs.remove(streamId)
  val _2 = state.exchanges.remove(streamId);
  ()
}

// The peer reset the stream (or the FSM failed it): abort the handler's
// response and drop the stream's send state.
func h2DropStream(state: in H2ConnState, streamId: in Int): Unit {
  match mapGet(state.exchanges, streamId) {
    case Some(x) -> h2Abort(x)
    case None -> ()
  }
  h2FinishStream(state, streamId)
}

// Connection teardown: refuse further responses and abort every in-flight
// exchange. `closed` is set before the registered exchanges are aborted, and a
// handler re-checks it after publishing (`h2Notify`), so no exchange is missed.
func h2Teardown(state: in H2ConnState): Unit {
  state.link.closed = true
  val ids = mapKeys(state.exchanges).toArray()
  var i = 0
  while i < ids.length {
    match mapGet(state.exchanges, ids[i]) {
      case Some(x) -> h2Abort(x)
      case None -> ()
    }
    i = i + 1
  }
  // Let a reader task parked on its credit wake up and observe the closed socket.
  val _ = semRelease(state.inCredit);
  ()
}

func h2WriteOrClose(state: in H2ConnState, bytes: in slice[Byte]): Unit {
  if bytes.length > 0 {
    match hostWrite(state.conn, bytes) {
      case Ok(_) -> ()
      case Err(_) -> {
        state.open = false
      }
    }
  }
}

// Send the response HEADERS for `so`, or reset the stream if they cannot be
// encoded.
func h2SendHeaders(state: in H2ConnState, so: in H2Out): Unit {
  val x = so.exchange
  val headers: List[HeaderField] = newList()
  headers.add(HeaderField(name = ":status", value = toString(x.status)))
  if x.contentType.length > 0 and H2.isH2ResponseFieldSafe("content-type", x.contentType) {
    headers.add(HeaderField(name = "content-type", value = x.contentType))
  }
  // A chunked response has no length up front.
  if not x.chunked {
    headers.add(HeaderField(name = "content-length", value = toString(x.bodyLength)))
  }
  appendH2ExtraHeaders(headers, x.extra)
  val endOnHeaders = (not x.chunked) and x.bodyLength == 0
  match H2.encodeResponseHeaders(state.h2, x.streamId, headers, endOnHeaders) {
    case Err(_) -> {
      // The response headers could not be HPACK-encoded: reset the stream with
      // RST_STREAM(INTERNAL_ERROR) (RFC 9113 section 6.4) so the client sees a
      // definite stream failure rather than a hang.
      h2WriteOrClose(state, H2.sendRstStream(state.h2, x.streamId, H2InternalError))
      h2Abort(x)
      so.finished = true
    }
    case Ok(headBytes) -> {
      h2WriteOrClose(state, headBytes)
      so.headersSent = true
      if endOnHeaders {
        so.finished = true
      }
    }
  }
}

// Advance one stream by at most one frame. Returns true when it made progress
// (wrote HEADERS or a DATA frame, or took a chunk); false when it is idle
// (nothing queued) or blocked on the peer's flow-control window. The connection
// task is the only caller, so the HPACK encoder and the flow windows are never
// touched concurrently with the reader (which only moves bytes).
func h2StepOut(state: in H2ConnState, so: in H2Out): Bool {
  val x = so.exchange
  if x.aborted {
    so.finished = true
    return false
  }
  if not so.headersSent {
    if not x.started {
      return false
    }
    h2SendHeaders(state, so)
    return true
  }
  if not so.hasCur {
    // `ended` is read before the dequeue: the handler enqueues every chunk
    // before it sets `ended`, so a miss with `ended` already true is final.
    val ended = x.ended
    var c: H2Chunk = default()
    if cqTryDequeue(x.chunks, c) {
      so.cur = c.bytes
      so.curOff = 0
      so.hasCur = true
      h2ReleaseCredit(x)
    } else if ended {
      match H2.sendData(state.h2, x.streamId, emptyBytes(), true) {
        case Ok(bytes) -> h2WriteOrClose(state, bytes)
        case Err(_) -> ()
      }
      so.finished = true
      return true
    } else {
      return false
    }
  }
  val sendable = H2.maxSendableOnStream(state.h2, x.streamId)
  if sendable <= 0 {
    return false
  }
  val remaining = so.cur.length - so.curOff
  val frameLen = minIntH2(minIntH2(H2.peerMaxFrameSize(state.h2), sendable), remaining)
  val exhausts = frameLen == remaining
  var isLast = false
  if exhausts {
    // Look ahead so END_STREAM rides the final DATA frame when the body is
    // already complete, as it always has for a buffered response.
    val ended = x.ended
    var nxt: H2Chunk = default()
    if cqTryDequeue(x.chunks, nxt) {
      so.hasNext = true
      so.next = nxt.bytes
      h2ReleaseCredit(x)
    } else {
      isLast = ended
    }
  }
  // A slice that fits one frame is framed as-is, without a sub-slice copy.
  val chunk = if so.curOff == 0 and frameLen == so.cur.length {
    so.cur
  } else {
    so.cur.slice(so.curOff, so.curOff + frameLen)
  }
  match H2.sendData(state.h2, x.streamId, chunk, isLast) {
    case Ok(bytes) -> h2WriteOrClose(state, bytes)
    case Err(_) -> {
      // The stream is no longer writable (reset or closed under us): stop.
      h2Abort(x)
      so.finished = true
      return true
    }
  }
  if exhausts {
    if so.hasNext {
      so.cur = so.next
      so.curOff = 0
      so.hasNext = false
    } else {
      so.hasCur = false
      so.cur = emptyBytes()
    }
  } else {
    so.curOff = so.curOff + frameLen
  }
  if isLast {
    so.finished = true
  }
  true
}

// One scheduling pass over every stream that has a response in flight, in
// arrival order, each advancing by at most one frame: this is what interleaves
// the DATA of concurrent streams instead of finishing one before starting the
// next. Returns whether any stream progressed.
func h2SendPass(state: in H2ConnState): Bool {
  var progress = false
  val ids = state.order.toArray()
  val keep: List[Int] = newList()
  var i = 0
  while i < ids.length {
    val id = ids[i]
    match mapGet(state.outs, id) {
      case None -> ()
      case Some(so) -> {
        if state.open and not H2.isFailed(state.h2) {
          if h2StepOut(state, so) {
            progress = true
          }
        }
        if so.finished {
          h2FinishStream(state, id)
        } else {
          keep.add(id)
        }
      }
    }
    i = i + 1
  }
  state.order = keep
  progress
}

// Register the streams handlers have published a response for.
func h2DrainOutbox(state: in H2ConnState): Unit {
  var n: H2Notice = default()
  while cqTryDequeue(state.link.outbox, n) {
    match mapGet(state.exchanges, n.streamId) {
      case None -> ()
      case Some(x) -> {
        match mapGet(state.outs, n.streamId) {
          case Some(_) -> ()
          case None -> {
            state.outs.add(
              n.streamId,
              H2Out(
                exchange = x,
                headersSent = false,
                hasCur = false,
                cur = emptyBytes(),
                curOff = 0,
                hasNext = false,
                next = emptyBytes(),
                finished = false
              )
            )
            state.order.add(n.streamId)
          }
        }
      }
    }
  }
}

// The reader's end-of-input marker arrived. Whether the peer half-closed after
// sending its requests or the transport failed, responses still being produced
// are written (a write to a dead socket closes the connection through
// `h2WriteOrClose`). The watchdog bounds the wait by the idle timeout so a
// handler that never responds cannot hold the connection open.
func h2BeginDrain(state: in H2ConnState): Unit {
  if not state.draining {
    state.draining = true
    val timeoutMs = resolveConnectionIdleTimeoutMs()
    val _watchdog = taskRun({ -> h2DrainWatchdog(state, timeoutMs) });
    ()
  }
}

// Sleeps in short slices until the connection ends or `timeoutMs` has passed;
// in the latter case it marks the drain expired and wakes the connection task.
func h2DrainWatchdog(state: in H2ConnState, timeoutMs: in Int): Unit {
  var waited = 0
  while waited < timeoutMs and not state.link.closed {
    sleepMillis(h2DrainWatchSliceMs)
    waited = waited + h2DrainWatchSliceMs
  }
  if not state.link.closed {
    state.drainExpired = true
    val _ = semRelease(state.link.wake);
    ()
  }
}

// True once a draining connection has nothing left to wait for.
func h2DrainFinished(state: in H2ConnState): Bool = state.draining and (state.drainExpired or state.exchanges.count == 0)

// Feed everything the reader task has queued into the connection FSM. A
// zero-length entry is the reader's end-of-input marker.
func h2DrainInbound(state: in H2ConnState): Unit {
  var ib: H2Inbound = default()
  while state.open and cqTryDequeue(state.inbound, ib) {
    val _ = semRelease(state.inCredit)
    if ib.bytes.length == 0 {
      h2BeginDrain(state)
    } else {
      processH2Batch(state, ib.bytes)
    }
  }
}

// One wake-up of the connection task: absorb input, register new responses, and
// write frames until every stream is idle or blocked on the peer's window.
func h2Cycle(state: in H2ConnState): Unit {
  var again = true
  while again and state.open and not H2.isFailed(state.h2) {
    h2DrainInbound(state)
    h2DrainOutbox(state)
    again = h2SendPass(state)
  }
}

// The per-connection reader: moves socket bytes into the inbound queue and
// nothing else, so the connection task can wait on one signal for both input and
// handler output. Each read is copied (the transport reuses its read buffer).
func h2ReadLoop(conn: in Conn, inbound: in ConcurrentQueue[H2Inbound], wake: in Semaphore, inCredit: in Semaphore): Unit {
  var go = true
  while go {
    semWait(inCredit)
    match hostRead(conn, 65536) {
      case Err(_) -> {
        go = false
      }
      case Ok(bytes) -> {
        if bytes.length == 0 {
          go = false
        } else {
          cqEnqueue(inbound, H2Inbound(bytes = bytes.slice(0, bytes.length)))
          val _ = semRelease(wake);
          ()
        }
      }
    }
  }
  cqEnqueue(inbound, H2Inbound(bytes = emptyBytes()))
  val _ = semRelease(wake);
  ()
}

// Dispatch a fully-received request stream: build an `HttpContext` (h2 mailbox
// attached) and hand it to the pull queue. The connection task does not wait
// for the response: the handler's `respond*` / chunked calls publish it, and
// the scheduler frames it, so a slow handler never delays other streams.
func dispatchH2Stream(state: in H2ConnState, streamId: in Int): Unit {
  match mapGet(state.accums, streamId) {
    case None -> ()
    case Some(accum) -> {
      val line = extractH2Request(accum.headers)
      val exchange = H2Exchange(
        streamId = streamId,
        link = state.link,
        chunks = newConcurrentQueue(),
        credit = newSemaphore(h2StreamChunkCredits),
        status = 0,
        contentType = "",
        extra = newMap(),
        bodyLength = 0,
        chunked = false,
        started = false,
        ended = false,
        aborted = false
      )
      state.exchanges.add(streamId, exchange)
      val someH2: Option[H2Exchange] = Some(value = exchange)
      val done: Semaphore = newSemaphore(0)
      val ctx = HttpContext(
        conn = state.conn,
        method = line.method,
        target = line.target,
        version = Http1_1,
        headers = line.headers,
        body = accum.body.toArray(),
        keepAlive = true,
        done = done,
        h2 = someH2,
        handoff = ConnHandoff(),
        trailingInput = false
      )
      removeAccum(state, streamId)
      cqEnqueue(state.queue, ctx)
      val _ = semRelease(state.available);
      ()
    }
  }
}

func onH2Headers(state: in H2ConnState, streamId: in Int, headers: in List[HeaderField], endStream: in Bool): Unit {
  if isRejectedStream(state, streamId) {
    // Terminal rejection (over `maxBodyBytes`, #6144): a trailer HEADERS block
    // must NOT re-dispatch the already-413'd request, and acting on it must not
    // trip a protocol violation — drop it. Its END_STREAM closes the stream, so
    // prune the marker.
    if endStream {
      forgetRejectedStream(state, streamId)
    }
    return
  }
  val accum = getOrCreateAccum(state, streamId)
  if not accum.haveHeaders {
    accum.headers = headers
    accum.haveHeaders = true
  }
  // A second HEADERS on an open stream is trailers (§8.1); the request line and
  // fields are already captured, so only its END_STREAM matters.
  if endStream {
    dispatchH2Stream(state, streamId)
  }
}

// Receive-window credit (#7269). Rather than a `WINDOW_UPDATE` per DATA frame
// (two separately written frames for every frame received, an amplification for
// small frames), a window is topped back up to its initial size only once it has
// fallen to half of it, the usual strategy: the peer always keeps at least half
// a window of credit, so it never stalls waiting for us. The FSM's own receive
// windows are the source of truth, so the credit always equals what the FSM
// debited, padding included (#6305). Both updates due after one frame go out in
// a single write.
//
// `topUpStream` is false for bytes dropped on a rejected stream: that stream's
// window is deliberately not replenished (backpressure), while the connection
// window always is, so the other streams on the connection never stall.
func topUpReceiveWindows(state: in H2ConnState, streamId: in Int, topUpStream: in Bool): Unit {
  var frames = emptyBytes()
  val connInitial = H2.h2InitialWindow()
  val connWindow = H2.connectionReceiveWindow(state.h2)
  if connWindow <= connInitial / 2 {
    frames = frames.concat(H2.grantConnectionWindow(state.h2, connInitial - connWindow))
  }
  if topUpStream {
    val streamInitial = state.h2.localSettings.initialWindowSize
    val streamWindow = H2.streamReceiveWindow(state.h2, streamId)
    if streamWindow <= streamInitial / 2 and streamWindow < streamInitial {
      frames = frames.concat(H2.grantStreamWindow(state.h2, streamId, streamInitial - streamWindow))
    }
  }
  if frames.length > 0 {
    val _ = hostWrite(state.conn, frames);
    ()
  }
}

// Send a bodyless `413` response with END_STREAM on `streamId` (RFC 9110 §15.5.14).
// Used when a request body exceeds `maxBodyBytes`; the stream is not dispatched to
// the handler.
func sendH2Reject413(state: in H2ConnState, streamId: in Int): Unit {
  val headers: List[HeaderField] = newList()
  headers.add(HeaderField(name = ":status", value = "413"))
  headers.add(HeaderField(name = "content-length", value = "0"))
  match H2.encodeResponseHeaders(state.h2, streamId, headers, true) {
    case Err(_) -> {
      // The 413 headers could not be HPACK-encoded: rather than silently
      // dropping the response and leaving the stream hanging, reset it with
      // RST_STREAM(INTERNAL_ERROR) (RFC 9113 section 6.4) so the client sees a
      // definite stream failure.
      val rst = H2.sendRstStream(state.h2, streamId, H2InternalError)
      if rst.length > 0 {
        val _ = hostWrite(state.conn, rst);
        ()
      }
    }
    case Ok(bytes) -> {
      val _ = hostWrite(state.conn, bytes);
      ()
    }
  }
}

func onH2Data(state: in H2ConnState, streamId: in Int, data: in slice[Byte], endStream: in Bool): Unit {
  if isRejectedStream(state, streamId) {
    // Dropped bytes still give back connection-level window so the other
    // streams on the connection never stall.
    topUpReceiveWindows(state, streamId, false)
    // Already terminally rejected (#6144): drop further DATA (never buffer past
    // the cap); its END_STREAM closes the stream, so prune the marker.
    if endStream {
      forgetRejectedStream(state, streamId)
    }
    return
  }
  val accum = getOrCreateAccum(state, streamId)
  if accum.body.count + data.length > state.limits.maxBodyBytes {
    // Reject terminally: cap the memory (do not append this frame), mark the
    // stream (which drops its accumulator, #6145), and send a 413. Matches the
    // HTTP/1.1 path, which rejects an oversized body as `BodyTooLarge` at
    // `maxBodyBytes`.
    markRejectedStream(state, streamId)
    topUpReceiveWindows(state, streamId, false)
    sendH2Reject413(state, streamId)
    if endStream {
      forgetRejectedStream(state, streamId)
    }
    return
  }
  appendBytes(accum.body, data)
  // Under the cap: stream-level window is topped up too, so a large legal body
  // can exceed the 64 KiB initial receive window (not once the peer has ended
  // the stream: no further DATA can arrive on it).
  topUpReceiveWindows(state, streamId, not endStream)
  if endStream {
    dispatchH2Stream(state, streamId)
  }
}

func processH2Event(state: in H2ConnState, ev: in H2.H2Event): Unit {
  match ev {
    case H2NeedMore -> ()
    case H2SettingsReceived(_) -> ()
    case H2SettingsAcknowledged -> ()
    case H2WindowUpdated(_) -> ()
    case H2PingReceived(_) -> ()
    case H2PingAcknowledged(_) -> ()
    case H2GoAwayReceived(_, _) -> ()
    case H2PeerReset(streamId, _) -> {
      removeAccum(state, streamId)
      forgetRejectedStream(state, streamId)
      h2DropStream(state, streamId)
    }
    case H2StreamErr(streamId, _, _) -> {
      removeAccum(state, streamId)
      forgetRejectedStream(state, streamId)
      h2DropStream(state, streamId)
    }
    case H2ConnError(_, _) -> {
      // The FSM already queued a GOAWAY in the feed's outbound bytes and poisoned
      // the connection; stop reading.
      state.open = false
    }
    case H2RequestHeaders(streamId, headers, endStream) -> onH2Headers(state, streamId, headers, endStream)
    case H2RequestData(streamId, data, endStream, _) -> onH2Data(state, streamId, data, endStream)
  }
}

func processH2Batch(state: in H2ConnState, bytes: in slice[Byte]): Unit {
  val work: List[H2.H2Event] = newList()
  h2Feed(state, bytes, work)
  var i = 0
  while i < work.count and state.open and not H2.isFailed(state.h2) {
    processH2Event(state, work[i])
    i = i + 1
  }
  // Once per batch, mirroring `H2.feed`'s own `pruneClosedStreams` cadence
  // (#6566) — pointless (and `H2.sendRstStream` would no-op anyway) once the
  // connection is closing or already fatal.
  if state.open and not H2.isFailed(state.h2) {
    pruneRejectedStreams(state)
  }
}

// The per-connection h2 connection task: send the server's initial SETTINGS,
// start the reader task, then loop on the wake signal, running one scheduling
// cycle (`h2Cycle`) per wake until the connection closes or fails. This task
// alone feeds the FSM, encodes HPACK and writes frames; the reader only moves
// socket bytes and handlers only publish response values, so the FSM state has
// a single owner.
func processH2Connection(
  conn: in Conn,
  queue: in ConcurrentQueue[HttpContext],
  available: in Semaphore,
  limits: in EngineLimits,
  connLimit: in Semaphore,
): Unit {
  // Guarantee socket close + concurrency-permit release even if the initial
  // `hostWrite` or `processH2Batch` throws on a broken socket — otherwise a
  // fire-and-forget `taskRun` exception leaks the #6071 permit and eventually
  // wedges the accept loop on `semWait(connLimit)` (#6221).
  defer {
    hostClose(conn)
    val _ = semRelease(connLimit)
  }
  val h2 = H2.newServerConnection(H2.h2DefaultServerSettings())
  val _ = hostWrite(conn, H2.serverInitialFrame(h2))
  val wake = newSemaphore(0)
  val inCredit = newSemaphore(h2InboundCredits)
  val inbound: ConcurrentQueue[H2Inbound] = newConcurrentQueue()
  val link = H2Link(closed = false, outbox = newConcurrentQueue(), wake = wake)
  val state = H2ConnState(
    conn = conn,
    h2 = h2,
    accums = newMap(),
    queue = queue,
    available = available,
    open = true,
    draining = false,
    drainExpired = false,
    link = link,
    inbound = inbound,
    inCredit = inCredit,
    exchanges = newMap(),
    outs = newMap(),
    order = newList(),
    limits = limits,
    rejectedStreams = newMap()
  )
  val _reader = taskRun({ -> h2ReadLoop(conn, inbound, wake, inCredit) })
  // Teardown runs however the loop ends (peer close, FSM failure, a throw), so
  // no handler stays blocked on a connection that is gone.
  defer {
    h2Teardown(state)
  }
  while state.open and not H2.isFailed(state.h2) {
    semWait(wake)
    h2Cycle(state)
    if h2DrainFinished(state) {
      state.open = false
    }
  };
  ()
}

// =====================================================================
// Public host helpers.
// =====================================================================
/// Construct + bind + start a plaintext listener for `prefix` (e.g.
/// `"http://localhost:8080/"`), using `EngineLimits.defaults()`. The caller
/// owns it and must call `stopListener` on shutdown. A `"*"` / `"+"` host binds
/// the IPv4 wildcard; `"localhost"` binds loopback. Use
/// `startListenerWithLimits` to raise the request-size caps.
pub func startListener(prefix: in String): HttpListener {
  startListenerWithLimits(prefix, EngineLimits.defaults())
}

/// Like `startListener`, but with caller-supplied `EngineLimits`. The retired
/// `HttpListener` server accepted unbounded request bodies; the sans-IO engine
/// defaults to a 10 MiB `maxBodyBytes` cap (`EngineLimits.defaults()`), so a
/// large-payload endpoint must raise the cap here (a custom `EngineLimits`
/// value, or `EngineLimits.defaults()` with a larger `maxBodyBytes`). Kept as a
/// separate function rather than a defaulted `startListener` parameter: a
/// cross-package `EngineLimits` default omitted at the call site would risk the
/// same multi-package bundle-build generic degradation this server's accept
/// loop was just hardened against.
pub func startListenerWithLimits(prefix: in String, limits: in EngineLimits): HttpListener {
  ensureServerThreadCapacity()
  val parsed = parsePrefix(prefix)
  match hostListen(resolveBindHost(parsed.bindHost), parsed.port) {
    case Ok(transport) -> {
      val queue: ConcurrentQueue[HttpContext] = newConcurrentQueue()
      val available = newSemaphore(0)
      val connLimit = newSemaphore(resolveMaxConcurrentConnections())
      val task = taskRun({ -> plainAcceptLoop(transport, queue, available, limits, connLimit) })
      HttpListener(transport = transport, queue = queue, available = available, acceptTask = task)
    }
    case Err(e) -> panic("Std.HttpServer.startListener: bind failed: " + TcpError.message(e))
  }
}

/// TLS twin of `startListener` (docs/61 §6.3, issue #5884), using
/// `EngineLimits.defaults()`. Binds `host`:`port` and terminates TLS on every
/// connection using `tls` (server identity, `minVersion`, ALPN `http/1.1`, and
/// callback-free mTLS). `host` is an IP literal, `"*"`/`"+"` (wildcard), or
/// `"localhost"`. Returns `Err(InvalidConfig(...))` for a mutual-TLS
/// misconfiguration (`requireClientCert` with no `clientCa`) or an identity the
/// platform cannot use, caught before binding. Each handshake runs on its
/// connection's own task under the `resolveTlsHandshakeTimeoutMs` timeout; a
/// failed or timed-out handshake drops that connection and is never fatal to
/// the listener. Use `startListenerTlsWithLimits` to raise the request-size
/// caps.
pub func startListenerTls(host: in String, port: in Int, tls: in TlsServerConfig): Result[HttpListener, TlsListenError] {
  startListenerTlsWithLimits(host, port, tls, EngineLimits.defaults())
}

/// Like `startListenerTls`, but with caller-supplied `EngineLimits` (see
/// `startListenerWithLimits` for why the cap is overridable and why this is a
/// separate function).
pub func startListenerTlsWithLimits(
  host: in String, port: in Int, tls: in TlsServerConfig, limits: in EngineLimits
): Result[HttpListener, TlsListenError] {
  val mtlsMisconfigured = tls.requireClientCert and match tls.clientCa { case Some(_) -> false; case None -> true }
  if mtlsMisconfigured {
    return Err(
      error = InvalidConfig(
        message = "requireClientCert is set but no clientCa is configured; mutual TLS must pin trust to a client CA " +
          "(refusing to bind a listener that would reject every connection)"
      )
    )
  }
  // Build the TLS state once for the listener's lifetime (#7268) rather than
  // per connection; an identity the platform cannot use fails here, before
  // binding, instead of on every handshake.
  val serverTls = match hostPrepareServerTls(tls) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = InvalidConfig(message = TcpError.message(e)))
  }
  ensureServerThreadCapacity()
  match hostListen(resolveBindHost(host), port) {
    case Ok(transport) -> {
      val queue: ConcurrentQueue[HttpContext] = newConcurrentQueue()
      val available = newSemaphore(0)
      val connLimit = newSemaphore(resolveMaxConcurrentConnections())
      val task = taskRun({ -> tlsAcceptLoop(transport, queue, available, serverTls, limits, connLimit) })
      Ok(value = HttpListener(transport = transport, queue = queue, available = available, acceptTask = task))
    }
    case Err(e) -> Err(error = InvalidConfig(message = "bind failed: " + TcpError.message(e)))
  }
}

/// Block until the next fully-parsed request is ready, returning its context.
pub func nextContext(l: in HttpListener): HttpContext {
  semWait(l.available)
  var ctx: HttpContext = default()
  // The semaphore is released once per enqueue, so an item is always present
  // here; a `false` return means the queue/semaphore invariant was violated
  // (never expected) — surface it loudly rather than returning a `default()`
  // context that would fault on first use.
  if not cqTryDequeue(l.queue, ctx) {
    panic(
      "Std.HttpServer.nextContext: request queue empty after its availability semaphore was signalled (invariant violation)"
    )
  }
  ctx
}

/// Stop accepting connections and release the socket. In-flight connection
/// tasks finish their current request; the accept loop ends when the stopped
/// listener's next accept fails.
pub func stopListener(l: in HttpListener): Unit {
  hostStopListener(l.transport)
}

/// HTTP method (`"GET"`, `"POST"`, ...).
pub func requestMethod(c: in HttpContext): String {
  c.method
}

/// Absolute path of the request target (everything before the first `?`).
pub func requestPath(c: in HttpContext): String {
  val q = queryStart(c.target)
  if q >= 0 {
    c.target.substring(0, q)
  } else {
    c.target
  }
}

/// Raw query string with no leading `?` (e.g. `"a=1&b=2"`), still
/// percent-escaped, or `""` if the target has none.
pub func requestQuery(c: in HttpContext): String {
  val q = queryStart(c.target)
  if q >= 0 {
    c.target.substring(q + 1, c.target.length - q - 1)
  } else {
    ""
  }
}

// Index of the first `?` in `target`, or -1.
func queryStart(target: in String): Int {
  var i = 0
  while i < target.length {
    if codeUnitAt(target, i) == 63 {
      return i
    }
    i = i + 1
  }
  0 - 1
}

/// Read the request body as a UTF-8 string (or `""` for an empty / non-UTF-8
/// body).
pub func requestBody(c: in HttpContext): String {
  match tryDecodeUtf8(c.body) {
    case Some(s) -> s
    case None -> ""
  }
}

/// Every request header as a name/value map. Multi-valued headers are
/// comma-joined (RFC 7230 §3.2.2), matching the old kernel and the JVM twin.
/// Names carry the case the client supplied; consumers (e.g. lyric-web's
/// `normalizeHeaders`) fold case before lookup.
pub func requestHeaders(c: in HttpContext): Map[String, String] {
  // Group first and join once per name: re-adding an existing key threw on
  // .NET (`Dictionary.Add`), so any request repeating a header name crashed
  // the handler, and joining on every repeat was quadratic (#7265).
  val grouped: Map[String, List[String]] = newMap()
  val names: List[String] = newList()
  var i = 0
  while i < c.headers.count {
    val h = c.headers[i]
    match mapGet(grouped, h.name) {
      case Some(values) -> values.add(h.value)
      case None -> {
        val values: List[String] = newList()
        values.add(h.value)
        grouped.add(h.name, values)
        names.add(h.name)
      }
    }
    i = i + 1
  }
  val result: Map[String, String] = newMap()
  var j = 0
  while j < names.count {
    match mapGet(grouped, names[j]) {
      case Some(values) -> result.add(names[j], joinList(",", values))
      case None -> ()
    }
    j = j + 1
  }
  result
}

func isHexDigit(c: in Char): Bool {
  val cp = toInt(c);
  (cp >= 48 and cp <= 57) or (cp >= 97 and cp <= 102) or (cp >= 65 and cp <= 70)
}

func hexDigitValue(c: in Char): Int {
  val cp = toInt(c)
  if cp >= 48 and cp <= 57 {
    cp - 48
  } else if cp >= 97 and cp <= 102 {
    cp - 97 + 10
  } else {
    cp - 65 + 10
  }
}

// A `%XX` escape (two hex digits) starts at `i`.  Reads code units, so any
// text around the escapes — supplementary-plane characters included — is
// passed over rather than indexed as a `Char`.
func isPercentEscapeAt(s: in String, i: in Int): Bool {
  i + 2 < s.length and codeUnitAt(s, i) == 37 and isHexDigit(charAtOrReplacement(s, i + 1)) and
    isHexDigit(charAtOrReplacement(s, i + 2))
}

/// Percent-decode a URL-encoded string (query/path segment values): `%XX` runs
/// decode as UTF-8 byte sequences (a multi-byte code point spans consecutive
/// `%XX` escapes, so a whole run is collected before decoding), `+` is NOT
/// treated as a space, and malformed escapes pass through literally.
pub func urlDecode(s: in String): String {
  val sb = StringBuilder.new()
  val len = s.length
  var litStart = 0
  var i = 0
  while i < len {
    if isPercentEscapeAt(s, i) {
      sb.append(s.substring(litStart, i - litStart))
      val runStart = i
      val bytes: List[Byte] = newList()
      while isPercentEscapeAt(s, i) {
        bytes.add((hexDigitValue(s[i + 1]) * 16 + hexDigitValue(s[i + 2])).toByte())
        i = i + 3
      }
      match tryDecodeUtf8(bytes.toArray()) {
        case Some(decoded) -> sb.append(decoded)
        case None -> sb.append(s.substring(runStart, i - runStart))
      }
      litStart = i
    } else {
      i = i + 1
    }
  }
  sb.append(s.substring(litStart, len - litStart))
  sb.toString()
}

// =====================================================================
// Response writing (runs on the puller thread).
// =====================================================================
// Mirror of `Std.HttpEngine`'s (package-private) response-safe byte rule (RFC
// 9110 §5.5 field-vchar / SP / HTAB, excluding CR/LF/NUL): the same predicate
// `serializeResponseHead`'s `requires:` enforces, replicated here because it is
// not exported. Pre-filtering to exactly this set keeps a hostile reflected
// header from tripping that contract and crashing the request loop.
func responseHeaderSafe(s: in String): Bool {
  var i = 0
  while i < s.length {
    val cp = codeUnitAt(s, i)
    if not ((cp >= 32 and cp <= 126) or cp == 9) {
      return false
    }
    i = i + 1
  }
  true
}

// Keep only response-safe header fields: a token name (`isFieldNameToken`) and
// a `responseHeaderSafe` value, exactly what `serializeResponseHead` requires.
// Filtering rather than panicking keeps one hostile reflected header from
// crashing the request loop.
func appendSafeHeader(headers: in List[HeaderField], name: in String, value: in String): Unit {
  if isFieldNameToken(name) and responseHeaderSafe(value) {
    headers.add(HeaderField(name = name, value = value))
  }
}

func appendExtraHeaders(headers: in List[HeaderField], extra: in Map[String, String]): Unit {
  val names = mapKeys(extra).toArray()
  var i = 0
  while i < names.length {
    val name = names[i]
    match mapGet(extra, name) {
      case Some(value) -> appendSafeHeader(headers, name, value)
      case None -> ()
    }
    i = i + 1
  }
}

// Standard connection-management headers: `Connection: close` when the exchange
// will not keep the connection alive, `Connection: keep-alive` on an HTTP/1.0
// keep-alive (HTTP/1.1 keep-alive is the default and needs no header).
func appendConnectionHeader(headers: in List[HeaderField], version: in HttpVersion, keepAlive: in Bool): Unit {
  if not keepAlive {
    headers.add(HeaderField(name = "Connection", value = "close"))
  } else {
    match version {
      case Http1_0 -> headers.add(HeaderField(name = "Connection", value = "keep-alive"))
      case Http1_1 -> ()
    }
  }
}

// Release the context's `done` semaphore so the connection task resumes. A
// failed write is not distinguished here — the broken socket surfaces on the
// task's next read (see `processConnection`).
func signalDone(c: in HttpContext): Unit {
  val _ = semRelease(c.done)
}

// A response status must be a three-digit code. Checked here, on the handler's
// thread and before either protocol path, so misuse panics where it happened:
// on HTTP/2 the status is only serialized later, on the connection task, where
// a failed `encodeResponseHeaders` precondition would take down every stream
// on the connection (#7251).
func checkResponseStatus(status: in Int): Unit {
  if status < 100 or status > 999 {
    panic("HTTP response status must be a three-digit code (100..999), got " + toString(status))
  }
}

func respondBytesWith(
  c: in HttpContext,
  status: in Int,
  contentType: in String,
  body: in slice[Byte],
  extra: in Map[String, String],
): Unit {
  checkResponseStatus(status)
  match c.h2 {
    case Some(exchange) -> {
      // HTTP/2: deliver the response into the stream's mailbox and hand off to
      // the connection task, which HPACK-encodes it and frames the body as DATA.
      // No wire write happens here (h2 FSM state is owned by the connection task).
      exchange.status = status
      exchange.contentType = contentType
      // A copy (one `Array.Copy`, #7259): the connection task frames it after
      // this call returns, so it must not alias a buffer the handler may reuse.
      addH2BodyChunk(exchange, body.slice(0, body.length))
      mapPutAll(exchange.extra, extra)
      exchange.chunked = false
      exchange.ended = true
      exchange.started = true
      h2Notify(exchange)
      signalDone(c)
    }
    case None -> {
      val headers: List[HeaderField] = newList()
      appendSafeHeader(headers, "Content-Type", contentType)
      headers.add(HeaderField(name = "Content-Length", value = toString(body.length)))
      appendConnectionHeader(headers, c.version, c.keepAlive)
      appendExtraHeaders(headers, extra)
      val head = serializeResponseHead(c.version, status, reasonForStatus(status), headers)
      val _ = hostWrite(c.conn, head.concat(body))
      signalDone(c)
    }
  }
}

/// Reply with a plaintext body; completes the exchange.
pub func respondText(c: in HttpContext, status: in Int, body: in String): Unit {
  val empty: Map[String, String] = newMap()
  respondBytesWith(c, status, "text/plain; charset=utf-8", encodeUtf8(body), empty)
}

/// Reply with `application/json`; completes the exchange. The body is passed
/// through verbatim — pre-format with `Std.Json.encodeString` for primitive
/// payloads, or hand-build complex shapes.
pub func respondJson(c: in HttpContext, status: in Int, body: in String): Unit {
  val empty: Map[String, String] = newMap()
  respondBytesWith(c, status, "application/json; charset=utf-8", encodeUtf8(body), empty)
}

/// Reply with a raw byte body plus extra response headers; completes the
/// exchange.
pub func respondBytesWithHeaders(
  c: in HttpContext,
  status: in Int,
  contentType: in String,
  body: in slice[Byte],
  headers: in Map[String, String],
): Unit {
  respondBytesWith(c, status, contentType, body, headers)
}

/// Take ownership of the transport connection under `c`, for a protocol
/// switch such as a WebSocket upgrade (RFC 9110 §7.8). Completes the
/// exchange in place of a `respond*` call: the connection task stops reading
/// HTTP requests from the connection and leaves it open, and the caller then
/// owns it, including writing any `101 Switching Protocols` response and
/// eventually calling `hostClose`. The connection no longer counts against
/// the listener's concurrent-connection cap.
///
/// Returns `Err` without touching the exchange when the request cannot be
/// handed over: an HTTP/2 stream (which shares its connection with other
/// streams), a request that is not HTTP/1.1, or a client that sent more
/// bytes after the request before any response. The caller then answers the
/// request with a `respond*` helper as usual.
///
/// Call at most once per context, and never after a `respond*` or
/// chunked-response helper has completed the exchange.
pub func takeConnection(c: in HttpContext): Result[Conn, String] {
  match c.h2 {
    case Some(_) -> return Err(error = "an HTTP/2 stream cannot take over its connection")
    case None -> ()
  }
  match c.version {
    case HttpVersion.Http1_1 -> ()
    case HttpVersion.Http1_0 -> return Err(error = "only an HTTP/1.1 connection can switch protocols")
  }
  if c.trailingInput {
    return Err(error = "the client sent data after the request before any response")
  }
  c.handoff.taken = true
  signalDone(c)
  Ok(value = c.conn)
}

// =====================================================================
// Chunked (streaming) responses.
//
// `beginChunkedResponse` commits status/content-type/extra headers with
// `Transfer-Encoding: chunked` (never a `Content-Length`) and returns an open
// stream handle; `streamWriteChunk` writes-and-flushes one chunk at a time
// (surfacing a broken connection as `Err`); `endChunkedResponse` writes the
// zero-length terminating chunk and completes the exchange. lyric-web's opt-in
// `serveStreaming` route table builds on these three.
// =====================================================================
/// Commit status + content-type + extra headers, switch the response into
/// chunked-transfer-encoding mode, and return the open stream handle to write
/// chunks to. No `Content-Length` is set.
pub func beginChunkedResponse(
  c: in HttpContext, status: in Int, contentType: in String, headers: in Map[String, String]
): HttpChunkedStream {
  checkResponseStatus(status)
  match c.h2 {
    case Some(exchange) -> {
      // HTTP/2 has no chunked transfer-encoding; the response is a HEADERS
      // frame followed by DATA frames. Publish the head now so the connection
      // task sends HEADERS immediately; each `streamWriteChunk` then queues a
      // chunk that is framed as DATA as soon as the peer's window allows, and
      // `endChunkedResponse` ends the stream.
      exchange.status = status
      exchange.contentType = contentType
      mapPutAll(exchange.extra, headers)
      exchange.chunked = true
      exchange.started = true
      h2Notify(exchange)
      val someH2: Option[H2Exchange] = Some(value = exchange)
      HttpChunkedStream(conn = c.conn, done = c.done, h2 = someH2)
    }
    case None -> {
      val respHeaders: List[HeaderField] = newList()
      appendSafeHeader(respHeaders, "Content-Type", contentType)
      respHeaders.add(HeaderField(name = "Transfer-Encoding", value = "chunked"))
      appendConnectionHeader(respHeaders, c.version, c.keepAlive)
      appendExtraHeaders(respHeaders, headers)
      val head = serializeResponseHead(c.version, status, reasonForStatus(status), respHeaders)
      val _ = hostWrite(c.conn, head)
      val noH2: Option[H2Exchange] = None
      HttpChunkedStream(conn = c.conn, done = c.done, h2 = noH2)
    }
  }
}

/// Write `bytes[offset..offset+count)` as one chunk and flush it immediately.
/// A zero-length write is a no-op (the terminating zero-length chunk is written
/// only by `endChunkedResponse`). `Err` surfaces a broken connection.
pub func streamWriteChunk(
  s: in HttpChunkedStream, bytes: in slice[Byte], offset: in Int, count: in Int
): Result[Unit, String] {
  if count <= 0 {
    return Ok(value = ())
  }
  val payload = bytes.slice(offset, offset + count)
  match s.h2 {
    case Some(exchange) -> {
      // HTTP/2: queue the chunk (already a fresh copy) for the connection task.
      // Blocks while `h2StreamChunkCredits` chunks are already waiting (a slow
      // peer), and fails once the stream was reset or the connection closed.
      if exchange.aborted {
        return Err(error = "the HTTP/2 stream was closed")
      }
      semWait(exchange.credit)
      if exchange.aborted {
        return Err(error = "the HTTP/2 stream was closed")
      }
      addH2BodyChunk(exchange, payload)
      h2Notify(exchange)
      Ok(value = ())
    }
    case None -> match hostWrite(s.conn, serializeChunk(payload)) {
      case Ok(_) -> Ok(value = ())
      case Err(e) -> Err(error = TcpError.message(e))
    }
  }
}

/// Write the terminating zero-length chunk and complete the exchange. Guarded:
/// a broken connection is swallowed (a disconnect mid-stream is routine and
/// must not crash the accept loop).
pub func endChunkedResponse(c: in HttpContext, s: in HttpChunkedStream): Unit {
  match s.h2 {
    case Some(exchange) -> {
      // HTTP/2: mark the body complete so the connection task ends the stream
      // (END_STREAM on the final DATA frame) once the queued chunks are sent.
      exchange.ended = true
      h2Notify(exchange)
      val _ = semRelease(s.done);
      ()
    }
    case None -> {
      val _ = hostWrite(s.conn, serializeLastChunk())
      val _ = semRelease(s.done);
      ()
    }
  }
}
