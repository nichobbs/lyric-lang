//! std/_kernel_native/http_server.l - native-target thread-per-connection
//! HTTP/1.1 server assembly on the sans-IO `Std.HttpEngine` + `Std.TcpHost`
//! transport (docs/61-https-tls-http-versions.md §7 item 5; N9.3 of epic
//! #5874 phase 5, issue #6104).
//!
//! Mirrors the dotnet (`_kernel/http_server.l`) / JVM (`_kernel_jvm/
//! http_server.l`) twins' twelve-function `Std.HttpServer` surface
//! (`startListener` / `nextContext` / `stopListener` / `requestMethod` /
//! `requestPath` / `requestBody` / `requestQuery` / `requestHeaders` /
//! `urlDecode` / `respondText` / `respondJson` / `respondBytesWithHeaders`)
//! plus `startListenerTls`, following the DOTNET twin's architecture (drive
//! `Std.HttpEngine`'s per-connection FSM over `Std.TcpHost`'s transport),
//! not the JVM twin's (which bypasses `Std.HttpEngine` entirely in favour of
//! the JDK's own `com.sun.net.httpserver.HttpServer`). Concurrency is
//! thread-per-connection over real `pthread_create`d OS threads (native
//! `spawn`/`scope` compiles to a single-threaded coroutine scheduler today,
//! D-N-022 — not the genuine OS concurrency this server needs; LLVM-coro
//! async service is a later item, docs/61 §7 item 5's own final sentence).
//!
//! ## Scope: v1 is HTTP/1.1 only, no h2
//!
//! Unlike the dotnet twin (which ships full h2/ALPN support, docs/61 §6.4),
//! this native twin implements ONLY the HTTP/1.1 half of `Std.HttpEngine` —
//! matching this issue's own text ("driving the sans-IO Std.HttpEngine's
//! FSM"; no h2 codepath is mentioned) and the JVM twin's precedent (which
//! also lacks h2 today). `_kernel_native/tcp_host.l`'s `hostAcceptTls`
//! unconditionally advertises `"h2,http/1.1"` as its ALPN preference (that
//! constant, `alpnPreference`, is shared with `Std.HttpHost`'s client kernel
//! and the TLS self-tests — narrowing it here would be a cross-cutting
//! change out of this item's scope), so a real HTTP/2-capable TLS client
//! that offers `h2` WOULD negotiate it even though this server cannot speak
//! it. `onAccepted` below guards against this explicitly: any connection
//! whose negotiated ALPN is `"h2"` is closed immediately rather than fed to
//! the HTTP/1.1 parser (which would otherwise silently misinterpret h2's
//! binary frame format as HTTP/1.1 text and either hang or emit garbage) —
//! a loud, documented gap, not a silent miscompile. Native ALPN-selected h2
//! is tracked as N9.5 (`native/plan/08-work-items.md`, issue #6106),
//! already gated on this item.
//!
//! ## Concurrency: mutex + counting semaphore over `lyric_mutex_*`/
//! `lyric_sem_*`, pointers stored as `Long`
//!
//! There is no BCL `ConcurrentQueue`/`SemaphoreSlim` equivalent on native, so
//! the pull-model hand-off (a background thread parses a request and blocks
//! until a puller thread responds to it, `_kernel/http_server.l`'s module
//! header) is built directly from the two primitives
//! D-progress-809/#6104 shipped for exactly this purpose:
//! `lyric_mutex_*` (mutual exclusion) guards a plain `List[HttpContext]`
//! FIFO queue, and `lyric_sem_*` (a counting semaphore — mutex+condvar
//! backed, since POSIX `sem_init` is unimplemented on macOS) both signals
//! "an item is available" (`ServerQueue.available`) and gives each request
//! its own one-shot "response written" handshake (`HttpContext.done`,
//! mirroring the dotnet twin's per-request `SemaphoreSlim`). Every raw
//! buffer handle (`lyric_mutex_init`/`lyric_sem_init` write into a
//! `malloc`'d block) is stored as `Long`, not `NativePtr[Byte]` — the exact
//! "opaque handle as integer" trick `_kernel_native/tcp_host.l`'s own module
//! header documents at length for `Conn.tlsConnHandle`: the mode checker's
//! N0100 boundary rejects a `NativePtr[T]` record/union FIELD outright
//! (heap storage outlives any frame), but `ServerQueue`/`HttpContext` must
//! survive across many separate calls on many separate threads, so their
//! raw handles are declared `Long` at both the extern's return position
//! (`rtMutexSize`-sized `rtMalloc`) and its parameter position (every later
//! `rtMutexLock`/`rtSemWait`/... call) — a pointer and an `i64` are the
//! identical machine word on every `--target native` triple (x86-64/AArch64,
//! both LP64), so nothing is lost by the reinterpretation.
//!
//! `List[HttpContext]`/`List[Long]` themselves are safe to share and mutate
//! across threads through a `Long`-keyed-mutex-guarded record reference: per
//! `native/plan/04-arc-design.md`, a Lyric `record` is a heap-allocated,
//! ARC-refcounted object on this target (unlike the self-hosted MSIL
//! emitter, which may lay out a generic record as a value type, docs/43) —
//! refcount increments/decrements are atomic (`_Atomic int rc`), and a
//! `lyric_mutex_lock`/`unlock` pair supplies the memory-visibility barrier a
//! plain field/list mutation needs to be safely observed by another thread.
//! `ServerQueue`/`HttpContext` are therefore ordinary (non-opaque) records
//! with package-private fields, following the same "public type, private
//! fields, explicit lifetime" discipline every other `_kernel_native/` file
//! already uses for a raw resource (`tcp_host.l`'s `Listener`/`Conn`,
//! `process_capture_host.l`'s `ProcessCaptureResult`).
//!
//! ## Shutdown: `stopListener` deterministically joins every spawned thread
//!
//! The dotnet twin's own `stopListener` doc comment is explicit that it does
//! NOT wait for in-flight connections ("the accept loop ends when the
//! stopped listener's next accept fails"; connection tasks finish
//! independently, garbage-collected once idle). That fire-and-forget model
//! is safe on a GC'd target but would leak this file's `malloc`'d
//! mutex/semaphore buffers on native (and, worse, risks a use-after-free if
//! a still-running connection thread later touched a queue whose backing
//! buffer this function had already freed). `stopListener` here instead: (1)
//! closes the transport, unblocking the accept thread's `hostAccept`/
//! `hostAcceptTls` call with an error so its own loop ends; (2) `pthread_join`s
//! the accept thread (a POSIX thread's own termination synchronizes-with its
//! joiner, so by the time this returns, every `ServerQueue.workerTids.add`/
//! `activeConns.add` call the accept thread's own connection-spawning path
//! could ever make has already happened and is visible here with no extra
//! locking needed); (3) `hostShutdown`s every still-registered connection
//! (see below); (4) `pthread_join`s every handler thread the accept thread
//! ever spawned; only then (5) frees the queue's mutex/semaphore. This makes
//! `stopListener` BLOCK until every accepted connection has genuinely
//! finished (a real behavioural difference from the dotnet/JVM twins, and
//! stronger than either — a caller wanting a non-blocking stop can spawn its
//! own thread to call it), the price of not having a GC to defer the cleanup
//! to.
//!
//! **Step (3) exists to fix a real deadlock (#6791), not a hypothetical
//! one.** `Std.HttpEngine.newConnection` defaults `keepAlive = true`, and
//! HTTP/1.1 keeps a connection open unless a request explicitly carries
//! `Connection: close` — so an ORDINARY, well-behaved HTTP/1.1 client that
//! is simply idle between requests leaves its handler thread parked in
//! `readOneRequest`'s `hostRead` indefinitely. Before this fix,
//! `stopListener` only ever closed the LISTENING socket
//! (`hostStopListener`), which does nothing to unblock a thread already
//! reading from an already-accepted connection — `pthread_join` on that
//! thread then never returns, and `stopListener` hangs forever. Every
//! accepted `Conn` is now tracked in `ServerQueue.activeConns` (added in
//! `registerWorker` alongside its handler thread's tid, removed in
//! `unregisterConn` — called strictly BEFORE, never after, that thread's own
//! `hostClose`, so `stopListener`'s shutdown loop can never touch an
//! already-closed, possibly fd-reused connection). `stopListener` calls
//! `Std.TcpHost.hostShutdown` (a raw `shutdown(fd, SHUT_RDWR)`, #6791 —
//! interrupts a blocked read/write from another thread WITHOUT releasing
//! the descriptor, unlike `hostClose`) on every still-registered connection
//! once the accept thread has fully joined (so no later-accepted connection
//! can be missed); the blocked `hostRead` then returns an error/EOF,
//! `readOneRequest` reports `RoClose`, and the handler thread exits through
//! its normal `defer` cleanup path.
//!
//! **The `hostShutdown` loop holds `q.mutex` for its entire duration, not
//! just the snapshot (#6795).** A connection can also finish NATURALLY and
//! concurrently with `stopListener` — an ordinary `Connection: close`
//! exchange completing while an operator asks the server to stop is the
//! common graceful-shutdown case under real load, not an edge case. Its
//! `processConnection` thread reaches its own `defer` block
//! (`unregisterConn` then `hostClose`) independently of `stopListener`, and
//! `unregisterConn` needs the SAME `q.mutex` to remove its entry.
//! Releasing the mutex between "read the snapshot" and "call
//! `hostShutdown` on each entry" (the original, buggy shape) left a window
//! where a connection captured in the snapshot could be unregistered AND
//! `hostClose`'d by its own thread before this loop's `hostShutdown` call
//! for it ran — shutting down an already-closed, possibly fd-reused
//! descriptor (exactly the hazard class #6791/#6792 already close for
//! their own narrower windows). Holding the mutex across the whole loop
//! makes that interleaving impossible: every entry this loop touches is
//! guaranteed still-registered (i.e. not yet `hostClose`'d) at the moment
//! of the call, not merely at the moment of an earlier, already-released
//! snapshot.
//!
//! **Before joining handler threads, `stopListener` also force-completes
//! any request that was `enqueueContext`'d but never pulled via
//! `nextContext`.** Unlike a context `nextContext` has ALREADY handed to
//! the caller (next paragraph), nothing outside the queue holds a
//! reference to a still-queued one, so draining `queue.items` and
//! releasing each entry's `done` semaphore here is safe — no later
//! `respond*` call can ever reach it once it is removed from the list.
//! Without this, the connection thread that enqueued it would stay parked
//! in `rtSemWait(doneSem)` forever (its own socket being `hostShutdown`'d
//! above does nothing for a thread blocked on a semaphore, not a socket
//! read), hanging the `tid`-join loop on a thread that could now never
//! finish.
//!
//! **What this does NOT fix, and why not: a context dequeued via
//! `nextContext` and never answered.** A handler thread can also be parked
//! in `rtSemWait(doneSem)` inside `processConnection`, waiting for a
//! `respond*` call on a context the CALLER has already pulled off the queue
//! (as opposed to the still-queued case just above, which this file DOES
//! now force-complete). Interrupting the connection's SOCKET does nothing
//! for a thread blocked on a SEMAPHORE — the two are unrelated primitives.
//! Force-`rtSemPost`ing such a semaphore from `stopListener` was considered
//! and rejected: nothing prevents the caller's own puller thread from ALSO
//! calling `respond*` on that same context after `stopListener`
//! force-posted and the connection thread already ran `freeOneShotSem` —
//! a genuine use-after-free on the `malloc`'d semaphore buffer, trading a
//! hang for memory corruption. This is not a native-specific gap either:
//! the dotnet twin's `stopListener` does not wait for in-flight
//! connections at all, so an abandoned dequeued context hangs there too
//! (forever, on a threadpool thread) — on every target, "call `respond*`
//! for whatever `nextContext` returns before shutting down" is the
//! caller's own obligation, not something the pull queue can enforce or
//! safely undo after the fact.
//!
//! No backpressure cap (the dotnet twin's `LYRIC_HTTP_MAX_CONNECTIONS`/
//! `resolveMaxConcurrentConnections`, #6071) ships in this v1: it needs
//! `Std.Parse.tryParseInt` to read the environment override, and
//! `Std.Parse` has no `_kernel_native/parse_host.l` twin yet (confirmed:
//! only `_kernel/parse_host.l` and `_kernel_jvm/parse_host.l` exist), so
//! depending on it here would either fail to build or silently punch a new
//! hole in the audited native stdlib-kernel boundary. A future
//! `Std.Parse` native twin removes this gap; until then, an unbounded
//! native listener is a disclosed, deliberate v1 scope decision, not a
//! silent omission.
//!
//! String scanning avoids `String[i]` bracket indexing throughout (not a
//! supported native codegen shape — `Lyric.LlvmCodegen.lowerCollectionIndex`
//! only recognises List/slice/Map receivers, confirmed via direct repro,
//! issue #6237) via two different idioms, chosen per call site: `.indexOf`/
//! `.startsWith`/`.substring` (native `String` methods shipped by #6588 /
//! D-progress-831, landed for this exact item) where a whole-needle search
//! reads more clearly, and a local `rtByteAt`-backed `charCodeAt` helper
//! (the same `lyric_string_byte_at` runtime accessor `Std.EncodingHost.
//! hostCharCodeAt` wraps — redeclared here rather than imported, since that
//! module's own header reserves it "only Std.Encoding should import this")
//! where per-character numeric range checks (`urlDecode`'s hex-escape
//! scanning, `parsePort`'s digit scanning) are the natural shape, matching
//! `_kernel/http_server.l`'s original `toInt(s[i])`-based logic byte-for-byte
//! once `s[i]` is replaced by `charCodeAt(s, i)`.
//!
//! `readOneRequest` avoids an `inout Connection` parameter: `Lyric.
//! LlvmCodegen`'s function-parameter lowering does not yet support `out`/
//! `inout` for `--target native` at all (an unconditional panic at every
//! such parameter position — this file's own `readOneRequest` was the
//! first native-backend code anywhere in the tree to try one, confirmed by
//! a real CI failure across all six self-test cases before this workaround
//! shipped; filed as issue #6794, a general tracked compiler gap, not
//! fixed here). `readOneRequest` instead takes `engineConn` `in` and
//! returns the advanced `Std.HttpEngine.Connection` bundled with its
//! `ReqOutcome` in a new `ReadOutcome` record; see that record's own doc
//! comment for the full reasoning.
@axiom("lyric_mutex_*/lyric_sem_* (lyric-rt/src/lyric_posix.c), pthread_create/pthread_join, and malloc/free conform to their documented POSIX/C99 contracts")
package Std.HttpServer

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Tls
import Std.HttpEngine
import Std.TcpHost

// =====================================================================
// Extern seam bindings.
// =====================================================================
extern func rtByteAt(s: String, idx: Int): Int = "lyric_string_byte_at"

extern func rtMalloc(n: Long): Long = "malloc"

extern func rtFree(p: Long): Unit = "free"

extern func rtMutexSize(): Int = "lyric_mutex_size"

extern func rtMutexInit(m: Long): Unit = "lyric_mutex_init"

extern func rtMutexLock(m: Long): Unit = "lyric_mutex_lock"

extern func rtMutexUnlock(m: Long): Unit = "lyric_mutex_unlock"

extern func rtMutexDestroy(m: Long): Unit = "lyric_mutex_destroy"

extern func rtSemSize(): Int = "lyric_sem_size"

extern func rtSemInit(s: Long, initial: Int): Unit = "lyric_sem_init"

extern func rtSemWait(s: Long): Unit = "lyric_sem_wait"

extern func rtSemPost(s: Long): Unit = "lyric_sem_post"

extern func rtSemDestroy(s: Long): Unit = "lyric_sem_destroy"

extern func pthreadCreate(tid: NativePtr[Long], attr: NativePtr[Byte], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = "pthread_create"

extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = "pthread_join"

func charCodeAt(s: in String, i: in Int): Int {
  rtByteAt(s, i)
}

// =====================================================================
// Public error type.
// =====================================================================
/// Failure returned by `startListenerTls`. `InvalidConfig` reports a
/// mutual-TLS misconfiguration (`requireClientCert` without a `clientCa`)
/// caught before binding, or a bind/thread-spawn failure. `NotSupportedOnTarget`
/// is retained for cross-target API stability but is never constructed here.
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

// =====================================================================
// Concurrency primitives: mutex-guarded FIFO queue + per-request one-shot
// semaphore (module header).
// =====================================================================
record ServerQueue {
  mutex: Long
  available: Long
  items: List[HttpContext]
  workerTids: List[Long]
  // Every currently-accepted, not-yet-closed connection (#6791): tracked so
  // `stopListener` can interrupt a handler thread idling in `hostRead` on a
  // keep-alive connection (Std.HttpEngine defaults `keepAlive = true`, so an
  // ordinary HTTP/1.1 client that never sends `Connection: close` leaves its
  // thread blocked here forever otherwise). A connection is registered the
  // moment its handler thread is spawned and unregistered strictly BEFORE
  // that thread's own `hostClose` call (never after) -- see
  // `unregisterConn`'s doc comment for why that ordering is load-bearing.
  activeConns: List[Conn]
}

func newServerQueue(): ServerQueue {
  val m = rtMalloc(rtMutexSize().toLong())
  rtMutexInit(m)
  val s = rtMalloc(rtSemSize().toLong())
  rtSemInit(s, 0)
  val items: List[HttpContext] = newList()
  val tids: List[Long] = newList()
  val conns: List[Conn] = newList()
  ServerQueue(mutex = m, available = s, items = items, workerTids = tids, activeConns = conns)
}

func enqueueContext(q: in ServerQueue, ctx: in HttpContext): Unit {
  rtMutexLock(q.mutex)
  q.items.add(ctx)
  rtMutexUnlock(q.mutex)
  rtSemPost(q.available)
}

func dequeueContext(q: in ServerQueue): HttpContext {
  rtSemWait(q.available)
  rtMutexLock(q.mutex)
  val ctx = q.items[0]
  q.items.removeAt(0)
  rtMutexUnlock(q.mutex)
  ctx
}

// Register `conn` into the active-connection registry. MUST be called
// BEFORE the connection's handler thread is spawned, never after (#6792):
// `pthread_create` starts the child running `processConnection`
// concurrently with the parent, and nothing forces the child to wait for a
// registration the parent hasn't made yet. If registration happened AFTER
// spawning, a connection that finishes its whole lifecycle fast (a
// health-check/port-scanner style connect-then-immediately-disconnect,
// common enough to not be a corner case) could reach `processConnection`'s
// `defer` block -- `unregisterConn` (a harmless no-op against an
// entry that doesn't exist yet) then `hostClose` -- before the parent's
// registration call ever runs; that registration would then add an
// ALREADY-CLOSED, potentially fd-reused `Conn` into the registry
// permanently (nothing would ever remove it again, since the one and only
// `unregisterConn` call for this connection already happened). Calling
// this first makes the child thread's own start strictly happen-after the
// entry already exists, so its `unregisterConn` can never race an add that
// hasn't happened yet.
func registerConn(q: in ServerQueue, conn: in Conn): Unit {
  rtMutexLock(q.mutex)
  q.activeConns.add(conn)
  rtMutexUnlock(q.mutex)
}

// Record a spawned handler thread's tid for `stopListener` to join. Safe to
// call any time after `pthread_create` returns successfully, including
// after the thread has already finished (`pthread_join` on an
// already-terminated, not-yet-joined thread still succeeds per POSIX) --
// unlike `registerConn`, there is no "stays stale forever" failure mode
// here to order against, since nothing ever re-removes a workerTids entry
// early the way `unregisterConn` does for `activeConns`.
func registerTid(q: in ServerQueue, tid: in Long): Unit {
  rtMutexLock(q.mutex)
  q.workerTids.add(tid)
  rtMutexUnlock(q.mutex)
}

// Remove `conn` from the active-connection registry. MUST be called by
// `conn`'s own owning (connection-handler) thread strictly BEFORE that same
// thread's `hostClose(conn)` call, never after: `stopListener`'s shutdown
// loop only ever calls `hostShutdown` (never `hostClose`) on a registry
// entry, but `hostShutdown` racing a `hostClose` on an ALREADY-CLOSED,
// possibly fd-reused connection is not safe (module header's "Shutdown"
// section, #6791) -- unregistering first guarantees this file's own
// `stopListener` can never observe (and therefore never touch) a
// connection whose fd this same thread is about to invalidate.
func unregisterConn(q: in ServerQueue, conn: in Conn): Unit {
  rtMutexLock(q.mutex)
  val targetFd = hostFd(conn)
  var idx = 0 - 1
  var i = 0
  while i < q.activeConns.count {
    if hostFd(q.activeConns[i]) == targetFd {
      idx = i
      break
    }
    i = i + 1
  }
  if idx >= 0 {
    q.activeConns.removeAt(idx)
  }
  rtMutexUnlock(q.mutex)
}

func newOneShotSem(): Long {
  val s = rtMalloc(rtSemSize().toLong())
  rtSemInit(s, 0)
  s
}

func freeOneShotSem(s: in Long): Unit {
  rtSemDestroy(s)
  rtFree(s)
}

// =====================================================================
// Public types.
// =====================================================================
/// A running server: the bound transport, the accept thread's id (joined by
/// `stopListener`), and the pull queue every spawned connection thread
/// shares. Opaque to consumers: observe it only through `nextContext` /
/// `stopListener`.
pub record HttpListener {
  transport: Listener
  acceptTid: Long
  queue: ServerQueue
}

/// One fully-parsed request plus the machinery to respond to it. `conn` is
/// the live transport connection (owned by the connection thread; a
/// `respond*` helper writes to it during the response phase, then releases
/// `done` so the connection thread may read the next request or close).
/// Treat the fields as private -- observe a context only through the
/// `request*` accessors and construct a response only through `respond*`.
pub record HttpContext {
  conn: Conn
  method: String
  target: String
  version: HttpVersion
  headers: List[HeaderField]
  body: slice[Byte]
  keepAlive: Bool
  done: Long
}

// =====================================================================
// Prefix parsing (pure Lyric) — accepts the "http://host:port/path" shape
// the dotnet/JVM twins' prefixes use. `https://` has no room for a TLS
// config and is rejected loudly (use `startListenerTls`).
// =====================================================================
func isDigitCp(cp: in Int): Bool {
  cp >= 48 and cp <= 57
}

func isHexDigitCp(cp: in Int): Bool {
  (cp >= 48 and cp <= 57) or (cp >= 97 and cp <= 102) or (cp >= 65 and cp <= 70)
}

func hexDigitCpValue(cp: in Int): Int {
  if cp >= 48 and cp <= 57 {
    cp - 48
  } else if cp >= 97 and cp <= 102 {
    cp - 97 + 10
  } else {
    cp - 65 + 10
  }
}

func parsePort(text: in String, prefix: in String): Int {
  if text.length == 0 {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': empty port")
  }
  var value = 0
  var i = 0
  while i < text.length {
    val cp = charCodeAt(text, i)
    if not isDigitCp(cp) {
      panic("Std.HttpServer: invalid listener prefix '" + prefix + "': non-numeric port '" + text + "'")
    }
    value = value * 10 + (cp - 48)
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
  val slashAt = rest.indexOf("/")
  val hostPort = if slashAt >= 0 { rest.substring(0, slashAt) } else { rest }
  val colonAt = hostPort.indexOf(":")
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

// `Std.TcpHost.hostListen` binds an IP literal, not a DNS name. Map the
// common non-literal binds the prefix convention uses.
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
// Response status reason phrases (RFC 9110-legal blank reason for an
// unlisted code, matching the dotnet/JVM twins).
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
// Per-connection request reader (runs on the connection thread).
// =====================================================================
union ReqOutcome {
  case RoClose
  case RoRequest(method: String, target: String, version: HttpVersion, headers: List[HeaderField], body: slice[Byte], keepAlive: Bool)
  case RoProtocolFail(status: Int)
}

// `readOneRequest`'s own return, bundling the outcome with the advanced
// engine FSM state. `Std.HttpEngine.feed` returns the FSM's next
// `Connection` value rather than mutating one in place (the engine has no
// concept of "the caller's local" at all), and `readOneRequest` drives
// `feed` in a loop across possibly-several socket reads for one logical
// request -- the natural signature would thread that advancing state
// through an `inout Connection` parameter, but `Lyric.LlvmCodegen`'s
// function-parameter lowering does not yet support `out`/`inout` for
// `--target native` (confirmed by direct repro: an unconditional panic at
// every `out`/`inout` parameter position, filed as #6794 as a general,
// tracked compiler gap -- not attempted here, following this file's own
// established "work around the native-codegen gap, don't fix the
// compiler" convention, e.g. the `Long`-as-pointer-handle trick for the
// `NativePtr[T]` record-field restriction). `readOneRequest` therefore
// takes `engineConn` `in` and returns the advanced `Connection` as part of
// this record instead; the caller (`processConnection`) reassigns its own
// local `var` from the result at each call.
record ReadOutcome {
  conn: Connection
  outcome: ReqOutcome
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
  val _ = hostWrite(conn, head)
}

// Read and parse exactly one request off `conn`, advancing the engine FSM.
// Drains any already-buffered (pipelined) bytes before issuing a fresh read.
func readOneRequest(conn: in Conn, initialEngineConn: in Connection): ReadOutcome {
  var engineConn = initialEngineConn
  var method = ""
  var target = ""
  var version: HttpVersion = Http1_1
  var headers: List[HeaderField] = newList()
  val body: List[Byte] = newList()
  var first = true
  while true {
    var events: List[HttpEvent] = newList()
    if first {
      first = false
      val fr0 = feed(engineConn, emptyBytes())
      engineConn = fr0.conn
      events = fr0.events
    } else {
      match hostRead(conn, 65536) {
        case Err(_) -> return ReadOutcome(conn = engineConn, outcome = RoClose)
        case Ok(bytes) -> {
          if bytes.length == 0 {
            return ReadOutcome(conn = engineConn, outcome = RoClose)
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
          return ReadOutcome(
            conn = engineConn,
            outcome = RoRequest(
              method = method,
              target = target,
              version = version,
              headers = headers,
              body = body.toArray(),
              keepAlive = not shouldClose(engineConn)
            )
          )
        }
        case ProtocolError(kind, _) -> return ReadOutcome(conn = engineConn, outcome = RoProtocolFail(status = protocolErrorStatus(kind)))
      }
      i = i + 1
    }
  }
  ReadOutcome(conn = engineConn, outcome = RoClose)
}

// Write a minimal bodyless error response (used for a `ProtocolError` before
// a context is ever handed to the puller) and always close the connection.
func writeErrorResponse(conn: in Conn, status: in Int): Unit {
  val headers: List[HeaderField] = newList()
  headers.add(HeaderField(name = "Content-Length", value = "0"))
  headers.add(HeaderField(name = "Connection", value = "close"))
  val head = serializeResponseHead(Http1_1, status, reasonForStatus(status), headers)
  val _ = hostWrite(conn, head)
}

// The per-connection thread body: parse a request, hand a ready context to
// the puller, block until the puller responds, then either read the next
// request (keep-alive) or close.
func processConnection(conn: in Conn, queue: in ServerQueue, limits: in EngineLimits): Unit {
  defer {
    // Order is load-bearing (#6791, `unregisterConn`'s doc comment):
    // unregister BEFORE closing, never after, so `stopListener`'s shutdown
    // loop can never touch this connection's fd once this thread has begun
    // invalidating it.
    unregisterConn(queue, conn)
    hostClose(conn)
  }
  var engineConn = newConnection(limits)
  var open = true
  while open {
    val readResult = readOneRequest(conn, engineConn)
    engineConn = readResult.conn
    match readResult.outcome {
      case RoClose -> {
        open = false
      }
      case RoProtocolFail(status) -> {
        writeErrorResponse(conn, status)
        open = false
      }
      case RoRequest(method, target, version, headers, body, keepAlive) -> {
        val doneSem = newOneShotSem()
        val ctx = HttpContext(
          conn = conn,
          method = method,
          target = target,
          version = version,
          headers = headers,
          body = body,
          keepAlive = keepAlive,
          done = doneSem
        )
        enqueueContext(queue, ctx)
        // Block until a respond helper releases `done`. A failed response
        // write is not signalled here -- the next `readOneRequest` hits the
        // broken socket and returns `RoClose`, closing the connection one
        // iteration later (mirrors the dotnet twin's identical reasoning).
        rtSemWait(doneSem)
        freeOneShotSem(doneSem)
        if not keepAlive {
          open = false
        }
      }
    }
  };
  ()
}

// Spawn one `pthread_create`d thread per accepted connection (module
// header). A spawn failure closes the connection rather than leaking it.
@unsafe_ffi
func spawnHandler(conn: in Conn, queue: in ServerQueue, limits: in EngineLimits): Unit {
  // Register BEFORE spawning (#6792, `registerConn`'s doc comment) -- never
  // the other way around.
  registerConn(queue, conn)
  var tid: Long = 0
  val worker: () -> NativePtr[Byte] = { -> processConnection(conn, queue, limits); nativeNullPtr() }
  val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)
  if rc == 0 {
    registerTid(queue, tid)
  } else {
    // The thread never started, so processConnection's own
    // unregisterConn/hostClose will never run for this connection --
    // undo the registration and close it here instead, or it would leak
    // into activeConns forever with no thread ever coming to remove it.
    unregisterConn(queue, conn)
    hostClose(conn)
  }
}

// Handle one accept result: on success, reject a negotiated-h2 connection
// (module header's "Scope: v1 is HTTP/1.1 only" section) or spawn a
// per-connection thread and keep looping; on a stopped listener
// (`AcceptFailed`/`BindFailed`) end the loop; any other per-connection
// failure (e.g. a TLS handshake that failed for one client) is skipped so
// one bad peer never takes the listener down.
func onAccepted(accepted: in Result[Conn, TcpError], queue: in ServerQueue, limits: in EngineLimits): Bool {
  match accepted {
    case Ok(conn) -> {
      if hostAlpn(conn) == "h2" {
        hostClose(conn)
        true
      } else {
        spawnHandler(conn, queue, limits)
        true
      }
    }
    case Err(e) -> match e { case AcceptFailed(_) -> false; case BindFailed(_) -> false; case _ -> true }
  }
}

func plainAcceptLoop(transport: in Listener, queue: in ServerQueue, limits: in EngineLimits): Unit {
  var running = true
  while running {
    val accepted = hostAccept(transport)
    running = onAccepted(accepted, queue, limits)
  }
}

func tlsAcceptLoop(
  transport: in Listener, queue: in ServerQueue, tls: in TlsServerConfig, limits: in EngineLimits
): Unit {
  var running = true
  while running {
    val accepted = hostAcceptTls(transport, tls)
    running = onAccepted(accepted, queue, limits)
  }
}

// =====================================================================
// Public API.
// =====================================================================
/// Construct + bind + start the server for `prefix` (e.g.
/// `"http://localhost:8080/"`). The caller owns it and must call
/// `stopListener` on shutdown. A `"*"` / `"+"` host binds the wildcard
/// address.
@unsafe_ffi
pub func startListener(prefix: in String): HttpListener {
  val parsed = parsePrefix(prefix)
  match hostListen(resolveBindHost(parsed.bindHost), parsed.port) {
    case Ok(transport) -> {
      val queue = newServerQueue()
      val limits = EngineLimits.defaults()
      var tid: Long = 0
      val worker: () -> NativePtr[Byte] = { -> plainAcceptLoop(transport, queue, limits); nativeNullPtr() }
      val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)
      if rc != 0 {
        panic("Std.HttpServer.startListener: failed to spawn the accept thread")
      }
      HttpListener(transport = transport, acceptTid = tid, queue = queue)
    }
    case Err(e) -> panic("Std.HttpServer.startListener: bind failed: " + TcpError.message(e))
  }
}

/// TLS twin of `startListener` (docs/61 §6.3, issue #5884), using
/// `EngineLimits.defaults()`. Binds `host`:`port` and terminates TLS on
/// every connection using `tls` (server identity, `minVersion`, mTLS). `host`
/// is an IP literal, `"*"`/`"+"` (wildcard), or `"localhost"`. Returns
/// `Err(InvalidConfig(...))` for a mutual-TLS misconfiguration
/// (`requireClientCert` with no `clientCa`) caught before binding, or a
/// bind/thread-spawn failure; per-connection handshake failures are handled
/// inside the accept loop, never fatal to the listener. A negotiated-h2
/// connection is dropped rather than parsed as HTTP/1.1 (module header).
@unsafe_ffi
pub func startListenerTls(host: in String, port: in Int, tls: in TlsServerConfig): Result[HttpListener, TlsListenError] {
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
      val queue = newServerQueue()
      val limits = EngineLimits.defaults()
      var tid: Long = 0
      val worker: () -> NativePtr[Byte] = { -> tlsAcceptLoop(transport, queue, tls, limits); nativeNullPtr() }
      val rc = pthreadCreate(nativeAddrOf(tid), nativeNullPtr(), worker, worker)
      if rc != 0 {
        return Err(error = InvalidConfig(message = "failed to spawn the accept thread"))
      }
      Ok(value = HttpListener(transport = transport, acceptTid = tid, queue = queue))
    }
    case Err(e) -> Err(error = InvalidConfig(message = "bind failed: " + TcpError.message(e)))
  }
}

/// Block until the next fully-parsed request is ready, returning its
/// context.
pub func nextContext(l: in HttpListener): HttpContext {
  dequeueContext(l.queue)
}

/// Stop accepting connections, then block until every accepted connection
/// has genuinely finished before releasing the queue's resources (module
/// header's "Shutdown" section — a stronger guarantee than the dotnet/JVM
/// twins', which never wait, because native has no GC to defer the cleanup
/// to).
@unsafe_ffi
pub func stopListener(l: in HttpListener): Unit {
  hostStopListener(l.transport)
  // Join the accept thread FIRST, before touching `activeConns`: its own
  // loop only ends once `hostAccept`/`hostAcceptTls` fails against the now-
  // closed listener, and every connection it accepts along the way is
  // registered synchronously (spawnHandler -> registerWorker) before the
  // loop's next iteration. Joining it first therefore guarantees the
  // `activeConns` snapshot taken below is the COMPLETE, final set -- no
  // connection accepted "too late" can be missed (#6791).
  var acceptOutp: NativePtr[Byte] = nativeNullPtr()
  val _ = pthreadJoin(l.acceptTid, nativeAddrOf(acceptOutp))
  // Interrupt every still-open connection's blocking hostRead (the common
  // case: an idle HTTP/1.1 keep-alive connection whose client hasn't sent
  // another request -- Std.HttpEngine defaults keepAlive = true, so this is
  // the default behavior for any well-behaved client, not an edge case,
  // #6791). hostShutdown wakes the blocked read with an error/EOF without
  // invalidating the fd, so the connection's own thread still safely
  // hostClose's it in its own defer block.
  //
  // The mutex is held across the ENTIRE snapshot-then-shutdown sequence,
  // not just the snapshot (#6795): a connection can also finish NATURALLY
  // and concurrently with `stopListener` (an ordinary `Connection: close`
  // exchange completing while an operator asks the server to stop is the
  // common graceful-shutdown case, not an edge case) -- its own
  // `processConnection` thread reaches its `defer` block
  // (`unregisterConn` then `hostClose`) independently of this function.
  // `unregisterConn` needs the SAME `q.mutex` to remove its entry, so
  // holding it here for the whole loop makes that removal impossible
  // while this loop is running: every entry this loop calls
  // `hostShutdown` on is therefore GUARANTEED to still be registered
  // (i.e. not yet `hostClose`'d, so its fd cannot have been reused
  // elsewhere in the process) at the moment of the call, not merely at
  // the moment of an earlier, since-released snapshot. `hostShutdown` is
  // a single syscall per entry, so holding the mutex for this bounded
  // loop is cheap.
  rtMutexLock(l.queue.mutex)
  val liveConns = l.queue.activeConns.toArray()
  var k = 0
  while k < liveConns.length {
    hostShutdown(liveConns[k])
    k = k + 1
  }
  rtMutexUnlock(l.queue.mutex)
  // Force-complete any request that was fully parsed and `enqueueContext`'d
  // but never pulled via `nextContext` before shutdown began. Unlike a
  // context `nextContext` has ALREADY handed to the caller (module
  // header's "What this does NOT fix" section -- force-completing THAT
  // one is unsafe, since the caller might still call `respond*` on it),
  // nothing outside this queue holds a reference to a still-queued
  // context, so draining it here and releasing its `done` semaphore is
  // safe: no later `respond*` call can ever reach it once it is removed
  // from `items`. Without this, the connection thread that enqueued it
  // would stay parked in `rtSemWait(doneSem)` forever (its own socket
  // being `hostShutdown`'d above does nothing for a thread blocked on a
  // semaphore, not a socket read), hanging the `tid`-join loop below on a
  // thread that can now never finish.
  rtMutexLock(l.queue.mutex)
  val abandoned = l.queue.items.toArray()
  l.queue.items.clear()
  rtMutexUnlock(l.queue.mutex)
  var j = 0
  while j < abandoned.length {
    rtSemPost(abandoned[j].done)
    j = j + 1
  }
  rtMutexLock(l.queue.mutex)
  val tids = l.queue.workerTids.toArray()
  rtMutexUnlock(l.queue.mutex)
  var i = 0
  while i < tids.length {
    var outp: NativePtr[Byte] = nativeNullPtr()
    val _ = pthreadJoin(tids[i], nativeAddrOf(outp))
    i = i + 1
  }
  rtMutexDestroy(l.queue.mutex)
  rtFree(l.queue.mutex)
  rtSemDestroy(l.queue.available)
  rtFree(l.queue.available)
}

/// HTTP method (`"GET"`, `"POST"`, ...).
pub func requestMethod(c: in HttpContext): String {
  c.method
}

// Index of the first `?` in `target`, or -1.
func queryStart(target: in String): Int {
  target.indexOf("?")
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

/// Read the request body as a UTF-8 string (or `""` for an empty /
/// non-UTF-8 body).
pub func requestBody(c: in HttpContext): String {
  match tryDecodeUtf8(c.body) {
    case Some(s) -> s
    case None -> ""
  }
}

/// Every request header as a name/value map. Multi-valued headers are
/// comma-joined (RFC 7230 §3.2.2), matching the dotnet/JVM twins. Names
/// carry the case the client supplied.
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

/// Percent-decode a URL-encoded string (query/path segment values): `%XX`
/// runs decode as UTF-8 byte sequences (a multi-byte code point spans
/// consecutive `%XX` escapes, so a whole run is collected before decoding),
/// `+` is NOT treated as a space, and malformed escapes pass through
/// literally.
pub func urlDecode(s: in String): String {
  var result = ""
  val len = s.length
  var i = 0
  while i < len {
    val cp = charCodeAt(s, i)
    if cp == 37 and i + 2 < len and isHexDigitCp(charCodeAt(s, i + 1)) and isHexDigitCp(charCodeAt(s, i + 2)) {
      val bytes: List[Byte] = newList()
      var raw = ""
      while i + 2 < len and charCodeAt(s, i) == 37 and isHexDigitCp(charCodeAt(s, i + 1)) and isHexDigitCp(charCodeAt(s, i + 2)) {
        val hi = hexDigitCpValue(charCodeAt(s, i + 1))
        val lo = hexDigitCpValue(charCodeAt(s, i + 2))
        bytes.add((hi * 16 + lo).toByte())
        raw = raw + s.substring(i, 3)
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
      result = result + s.substring(i, 1)
      i = i + 1
    }
  }
  result
}

// =====================================================================
// Response writing (runs on the puller thread).
// =====================================================================
// Mirror of `Std.HttpEngine`'s (package-private) response-safe byte rule
// (RFC 9110 §5.5 field-vchar / SP / HTAB, excluding CR/LF/NUL) --
// pre-filtering to exactly this set keeps a hostile reflected header value
// from tripping `serializeResponseHead`'s `requires:` and crashing the
// connection thread.
func responseHeaderSafe(s: in String): Bool {
  var i = 0
  while i < s.length {
    val cp = charCodeAt(s, i)
    if not ((cp >= 32 and cp <= 126) or cp == 9) {
      return false
    }
    i = i + 1
  }
  true
}

func appendSafeHeader(headers: in List[HeaderField], name: in String, value: in String): Unit {
  if name.length > 0 and responseHeaderSafe(name) and responseHeaderSafe(value) {
    headers.add(HeaderField(name = name, value = value))
  }
}

// `extra` is rebound to a freshly-annotated local (`m`) before either
// generic call: `Lyric.LlvmCodegen`'s generic-argument inference reads a
// literal or an explicitly-annotated local variable's type, not a
// function PARAMETER's own declared type, so `mapKeys(extra)`/
// `mapGet(extra, name)` (both keyed off `extra`'s parameter type alone)
// failed with "cannot infer type argument 'K'" on `--target native`
// (confirmed via direct repro) even though `extra: in Map[String, String]`
// is fully concrete at this call site. `requestHeaders` above already
// relies on the same "explicitly-annotated local" shape for its own
// `mapGet` call (`val result: Map[String, String] = newMap()`), proven to
// compile on native, so this mirrors an already-working pattern rather
// than introducing an untested one -- explicit type-argument application
// (`mapKeys[String, String](extra)`) was tried first but produces an
// `InvalidProgramException` on `--target dotnet` for this exact stdlib
// generic pair (a separate, MSIL-backend-specific bug in the explicit
// type-application path, not something to depend on here).
func appendExtraHeaders(headers: in List[HeaderField], extra: in Map[String, String]): Unit {
  val m: Map[String, String] = extra
  val names = mapKeys(m).toArray()
  var i = 0
  while i < names.length {
    val name = names[i]
    match mapGet(m, name) {
      case Some(value) -> appendSafeHeader(headers, name, value)
      case None -> ()
    }
    i = i + 1
  }
}

// `Connection: close` when the exchange will not keep the connection alive;
// `Connection: keep-alive` on an HTTP/1.0 keep-alive (HTTP/1.1's default
// needs no header).
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
  rtSemPost(c.done)
}

/// Reply with a plaintext body; completes the exchange.
pub func respondText(c: in HttpContext, status: in Int, body: in String): Unit {
  val empty: Map[String, String] = newMap()
  respondBytesWith(c, status, "text/plain; charset=utf-8", encodeUtf8(body), empty)
}

/// Reply with `application/json`; completes the exchange. The body is
/// passed through verbatim.
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
