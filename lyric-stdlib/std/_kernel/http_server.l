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
//! (`startListenerWithLimits` / `startListenerTlsWithLimits` are additive — the
//! only new public functions — for callers that need to raise the engine's
//! request-size caps). `HttpContext`
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
//! `Std.TcpHost.hostAcceptTls` (server identity + `minVersion` + ALPN
//! `http/1.1` + callback-free mTLS). The former phase-2 typed
//! `NotSupportedOnTarget` stub is gone. A mutual-TLS misconfiguration
//! (`requireClientCert` with no `clientCa`) is rejected up front with
//! `Err(InvalidConfig(...))` — the same security guard `Std.TcpHost`
//! enforces per-accept (#6042) — rather than binding a listener that would
//! reject every connection. Per-connection TLS handshake failures are handled
//! inside the accept loop (the connection is dropped; the server keeps
//! serving), never fatal to the listener.
//!
//! h2/ALPN end-to-end negotiation is out of scope here (issue #5889, gated on
//! the h2 FSM #5888): the transport advertises only `http/1.1`, so every
//! connection this server accepts speaks HTTP/1.1.
@axiom("System.Threading.Tasks.Task.Run, System.Collections.Concurrent.ConcurrentQueue, and System.Threading.SemaphoreSlim operations conform to their documented .NET contracts")
package Std.HttpServer

import Std.Core
import Std.Collections
import Std.Char
import Std.Encoding
import Std.Tls
import Std.HttpEngine
import Std.TcpHost

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
}

/// An open chunked (`Transfer-Encoding: chunked`) response. Carries the
/// connection the caller writes chunks to via `streamWriteChunk` and the
/// `done` semaphore `endChunkedResponse` releases to complete the exchange.
pub record HttpChunkedStream {
  conn: Conn
  done: Semaphore
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
    val c = text[i]
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
    if rest[i] == '/' {
      slashAt = i
    }
    i = i + 1
  }
  val hostPort = if slashAt >= 0 { rest.substring(0, slashAt) } else { rest }
  var colonAt = 0 - 1
  var j = 0
  while j < hostPort.length {
    if hostPort[j] == ':' {
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
  case RoRequest(method: String, target: String, version: HttpVersion, headers: List[HeaderField], body: slice[Byte], keepAlive: Bool)
  case RoProtocolFail(status: Int)
}

func emptyBytes(): slice[Byte] {
  val e: slice[Byte] = []
  e
}

func appendBytes(acc: in List[Byte], bytes: in slice[Byte]): Unit {
  var i = 0
  while i < bytes.length {
    acc.add(bytes[i])
    i = i + 1
  }
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
      val fr0 = feed(engineConn, emptyBytes())
      engineConn = fr0.conn
      events = fr0.events
    } else {
      match hostRead(conn, 65536) {
        case Err(_) -> return RoClose
        case Ok(bytes) -> {
          if bytes.length == 0 {
            return RoClose
          }
          val fr1 = feed(engineConn, bytes)
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
            keepAlive = not shouldClose(engineConn)
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
): Unit {
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
      case RoRequest(method, target, version, headers, body, keepAlive) -> {
        val done: Semaphore = newSemaphore(0)
        val ctx = HttpContext(
          conn = conn,
          method = method,
          target = target,
          version = version,
          headers = headers,
          body = body,
          keepAlive = keepAlive,
          done = done
        )
        cqEnqueue(queue, ctx)
        val _ = semRelease(available)
        // Block until a respond helper releases `done`. Keep-alive is the
        // engine's decision (`keepAlive`); a failed response write is not
        // signalled here — the next `readOneRequest` hits the broken socket and
        // returns `RoClose`, closing the connection one iteration later.
        semWait(done)
        if not keepAlive {
          open = false
        }
      }
    }
  }
  hostClose(conn)
}

// Handle one accept result: on success spawn a per-connection task and keep
// the loop running; on a stopped listener (`AcceptFailed`/`BindFailed`) end the
// loop; a per-connection TLS handshake failure (`hostAcceptTls` already closed
// that socket) is skipped so one bad client never takes the server down.
// Returns whether the accept loop should keep running.
func onAccepted(
  accepted: in Result[Conn, TcpError],
  queue: in ConcurrentQueue[HttpContext],
  available: in Semaphore,
  limits: in EngineLimits,
): Bool {
  match accepted {
    case Ok(conn) -> {
      val _ = taskRun({ -> processConnection(conn, queue, available, limits) })
      true
    }
    case Err(e) -> match e { case AcceptFailed(_) -> false; case BindFailed(_) -> false; case _ -> true }
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
): Unit {
  var running = true
  while running {
    val accepted = hostAccept(transport)
    running = onAccepted(accepted, queue, available, limits)
  }
}

// TLS accept loop — terminates TLS on each accepted connection using `cfg`.
func tlsAcceptLoop(
  transport: in Listener,
  queue: in ConcurrentQueue[HttpContext],
  available: in Semaphore,
  cfg: in TlsServerConfig,
  limits: in EngineLimits,
): Unit {
  var running = true
  while running {
    val accepted = hostAcceptTls(transport, cfg)
    running = onAccepted(accepted, queue, available, limits)
  }
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
  val parsed = parsePrefix(prefix)
  match hostListen(resolveBindHost(parsed.bindHost), parsed.port) {
    case Ok(transport) -> {
      val queue: ConcurrentQueue[HttpContext] = newConcurrentQueue()
      val available = newSemaphore(0)
      val task = taskRun({ -> plainAcceptLoop(transport, queue, available, limits) })
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
/// misconfiguration (`requireClientCert` with no `clientCa`) caught before
/// binding; per-connection handshake failures are handled inside the accept
/// loop, never fatal to the listener. Use `startListenerTlsWithLimits` to raise
/// the request-size caps.
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
  match hostListen(resolveBindHost(host), port) {
    case Ok(transport) -> {
      val queue: ConcurrentQueue[HttpContext] = newConcurrentQueue()
      val available = newSemaphore(0)
      val task = taskRun({ -> tlsAcceptLoop(transport, queue, available, tls, limits) })
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
    if target[i] == '?' {
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
  val result: Map[String, String] = newMap()
  var i = 0
  while i < c.headers.count {
    val h = c.headers[i]
    match mapGet(result, h.name) {
      case Some(existing) -> result.add(h.name, existing + "," + h.value)
      case None -> result.add(h.name, h.value)
    }
    i = i + 1
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

/// Percent-decode a URL-encoded string (query/path segment values): `%XX` runs
/// decode as UTF-8 byte sequences (a multi-byte code point spans consecutive
/// `%XX` escapes, so a whole run is collected before decoding), `+` is NOT
/// treated as a space, and malformed escapes pass through literally.
pub func urlDecode(s: in String): String {
  var result = ""
  val len = s.length
  var i = 0
  while i < len {
    val c = s[i]
    if c == '%' and i + 2 < len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2]) {
      val bytes: List[Byte] = newList()
      var raw = ""
      while i + 2 < len and s[i] == '%' and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2]) {
        bytes.add((hexDigitValue(s[i + 1]) * 16 + hexDigitValue(s[i + 2])).toByte())
        raw = raw + "%" + ("" + s[i + 1]) + ("" + s[i + 2])
        i = i + 3
      }
      match tryDecodeUtf8(bytes.toArray()) {
        case Some(decoded) -> {
          result = result + decoded
        }
        case None -> {
          result = result + raw
        }
      }
    } else {
      result = result + ("" + c)
      i = i + 1
    }
  }
  result
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
    val cp = toInt(s[i])
    if not ((cp >= 32 and cp <= 126) or cp == 9) {
      return false
    }
    i = i + 1
  }
  true
}

// Keep only response-safe header fields (see `responseHeaderSafe`). Filtering
// rather than panicking keeps one hostile reflected header value from crashing
// the request loop.
func appendSafeHeader(headers: in List[HeaderField], name: in String, value: in String): Unit {
  if name.length > 0 and responseHeaderSafe(name) and responseHeaderSafe(value) {
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

func respondBytesWith(
  c: in HttpContext,
  status: in Int,
  contentType: in String,
  body: in slice[Byte],
  extra: in Map[String, String],
): Unit {
  val headers: List[HeaderField] = newList()
  appendSafeHeader(headers, "Content-Type", contentType)
  headers.add(HeaderField(name = "Content-Length", value = toString(body.length)))
  appendConnectionHeader(headers, c.version, c.keepAlive)
  appendExtraHeaders(headers, extra)
  val head = serializeResponseHead(c.version, status, reasonForStatus(status), headers)
  val _ = hostWrite(c.conn, head.concat(body))
  signalDone(c)
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
  val respHeaders: List[HeaderField] = newList()
  appendSafeHeader(respHeaders, "Content-Type", contentType)
  respHeaders.add(HeaderField(name = "Transfer-Encoding", value = "chunked"))
  appendConnectionHeader(respHeaders, c.version, c.keepAlive)
  appendExtraHeaders(respHeaders, headers)
  val head = serializeResponseHead(c.version, status, reasonForStatus(status), respHeaders)
  val _ = hostWrite(c.conn, head)
  HttpChunkedStream(conn = c.conn, done = c.done)
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
  match hostWrite(s.conn, serializeChunk(payload)) {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = TcpError.message(e))
  }
}

/// Write the terminating zero-length chunk and complete the exchange. Guarded:
/// a broken connection is swallowed (a disconnect mid-stream is routine and
/// must not crash the accept loop).
pub func endChunkedResponse(c: in HttpContext, s: in HttpChunkedStream): Unit {
  val _ = hostWrite(s.conn, serializeLastChunk())
  val _ = semRelease(s.done)
}
