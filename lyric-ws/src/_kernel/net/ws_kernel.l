//! Ws.Kernel.Net — WebSocket connection registry and real server, on dotnet,
//! the JVM and native (docs/62-jsonrpc-mcp.md §6, #778; docs/73 S7a).
//!
//! Pure-Lyric RFC 6455 implementation on top of the `Std.TcpHost` transport
//! kernel (the same seam `Std.HttpServer`/`Std.HttpEngine` ride, docs/61
//! phase 3.3) — not ASP.NET Core WebSockets. Three composed layers, each
//! already shipped and tested:
//!
//!   * **Transport** — `Std.TcpHost`: `System.Net.Sockets.TcpListener` +
//!     `NetworkStream`, `Result[_, TcpError]` throughout.
//!   * **Handshake** — `Ws.Handshake`: a minimal HTTP/1.1 GET parser scoped
//!     to the upgrade request shape, plus `Sec-WebSocket-Accept` derivation.
//!   * **Frames** — `Ws.Frame`: a pure-Lyric RFC 6455 frame codec (FIN/RSV/
//!     opcode/mask/length, fragmentation reassembly, UTF-8 validation).
//!
//! Concurrency mirrors `Std.HttpServer`'s dotnet assembly (`_kernel/
//! http_server.l`, #5884): a background `Task` runs the accept loop, and
//! each accepted connection gets its own `Task` running a blocking
//! handshake + frame-read loop, plus (when ping keepalive is enabled) a
//! third `Task` sending periodic Ping frames (on the JVM each is a virtual
//! thread, on native a detached pthread). Lyric `spawn`/`scope` is
//! degenerate-synchronous on `--target dotnet` (D119/D120), so the real
//! OS-thread concurrency comes from `System.Threading.Tasks.Task.Run`, not
//! Lyric's own concurrency keywords — the same reasoning `_kernel/
//! http_server.l`'s header documents.
//!
//! `startServer`'s public signature (`Ws.kernelStartServer` in `ws.l`) has
//! no `pingIntervalMs` parameter — only `createRegistry` accepts one, and
//! only as bookkeeping (a pre-existing gap in `ws.l`'s public surface,
//! unrelated to this file, not touched here to keep this change scoped to
//! #778). To still deliver a genuine periodic keepalive (docs/62 §6 — "do
//! NOT replicate the JVM kernel's documented gaps... implement both
//! properly on dotnet"), `startServer` reads the interval directly from the
//! `LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS` env var `ws.l`'s own module
//! header already documents (default `30000`; `<= 0` disables pings, same
//! contract as `createRegistry`'s `pingIntervalMs` parameter).
//!
//! Outbound path (docs/73 S8, D792). Every frame an application, the
//! keepalive or the close handshake sends is appended to the connection's
//! own bounded queue (`ConnState`) and written by at most one drain task at a
//! time, so `send` and `broadcast` return as soon as the frame is queued and a
//! peer that stops reading stalls only itself: once its backlog passes
//! `ServerLimits.maxOutboundBytes`, or one write makes no progress for
//! `writeTimeoutMs`, the connection is aborted (`onError`, `onClose` with
//! 1008) and the socket shut down. One frame at a time reaches the socket, so
//! a ping keepalive and an application `send`/`close` call can never
//! interleave bytes on it. A single maintenance task per connection (the old
//! ping loop) also enforces the idle timeout, which is tied to ping liveness:
//! any received byte, a Pong included, resets it.
//!
//! Active on every target: feature = "dotnet", "jvm" or "native". The few
//! target-specific primitives (locks, background threads, sleep, handler
//! crash isolation, and on dotnet the concurrent dictionary) are in `ws_prims.l`
//! (dotnet), `_kernel/jvm/ws_prims.l` and `_kernel/native/ws_prims.l`; the
//! dictionary for `jvm` and `native` is `ws_dict.l`.
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(any(feature = "dotnet", feature = "jvm", feature = "native"))
@io
package Ws.Kernel.Net

import Std.Core
import Std.Console
import Resilience
import Std.Collections
import Std.Encoding
import Std.Environment
import Std.Parse
import Std.Time
import Std.Uuid
import Std.TcpHost
import Std.Tls
import Std.HttpServerHost as Hsh
import Ws.Frame
import Ws.Handshake

// ─── Limits ────────────────────────────────────────────────────────────────────
/// The per-server limits of docs/73 S8 (D792). A value of `0` disables the
/// limit it names, except `maxConnections`, where `0` means the target's
/// default (`Std.HttpServerHost.defaultMaxConnections`: 10 000 on the JVM,
/// 1 000 on dotnet and native, where every connection costs OS threads).
@stable(since = "0.4")
pub record ServerLimits {
  maxConnections: Int
  idleTimeoutMs: Int
  writeTimeoutMs: Int
  maxOutboundBytes: Int
  handshakeTimeoutMs: Int
}

/// The limits a server gets when none are given.
@stable(since = "0.4")
pub func defaultLimits(): ServerLimits {
  ServerLimits(
    maxConnections = 0,
    idleTimeoutMs = 90000,
    writeTimeoutMs = 10000,
    maxOutboundBytes = 1048576,
    handshakeTimeoutMs = 10000
  )
}

// How long a Close frame this side sent may wait for the peer's reply, and
// how long the read loop waits for its own reply to leave the queue, before
// the socket is shut down.
val closeHandshakeTimeoutMs: Int = 5000

// ─── Connection registry ──────────────────────────────────────────────────────
ref record RegistryMeta {
  var maxMessageSizeBytes: Int = 1024
  var pingIntervalMs: Int = 0
  var openCount: Int = 0
  lock: WsLock = newWsLock()
  onOpen: Option[(String, String, String, String, Map[String, String]) -> Unit] = None
  onMessage: Option[(String, String, String) -> Unit] = None
  onClose: Option[(String, Int, String) -> Unit] = None
  onError: Option[(String, String) -> Unit] = None
  var listener: Option[Listener] = None
  connIds: List[String] = newList()
  limits: ServerLimits = defaultLimits()
  var liveConnections: Int = 0
  var tls: Option[ServerTls] = None
  var upgrading: Int = 0
  var stopped: Bool = false
}

/// A single connection's live state. `conn` is `None` for a
/// bookkeeping-only entry (never populated by this file — kept `Option` for
/// symmetry with `RegistryMeta`'s callback fields and so `default()`'s
/// zero-init has a well-defined value). `closing` guards against sending a
/// Close frame twice (once we've sent one, whether app-initiated or as the
/// echo to a peer-initiated close, no further Close frame is sent).
///
/// `lock` guards every mutable field and is never held across a socket
/// operation. The outbound `queue` (frames from `queueHead` on; `queuedBytes`
/// counts the frames still queued plus the one being written) is drained by
/// one task at a time (`draining`); `writeStartNs` is when the write in flight
/// began (`0` when none), for the write timeout. `released` is set, under the
/// lock, before the socket is closed, so no thread shuts down or writes to a
/// descriptor the owner has already released. `abortCode`/`abortReason` are the
/// close code and reason reported to `onClose` when the connection ends with no
/// Close frame from the peer (an idle timeout, a slow consumer, a write
/// failure); `aborted` says the socket has been shut down.
ref record ConnState {
  var isOpen: Bool = false
  var closing: Bool = false
  conn: Option[Conn] = None
  lock: WsLock = newWsLock()
  handle: Int = 0
  connId: String = ""
  maxOutboundBytes: Int = 1048576
  queue: List[slice[Byte]] = newList()
  var queueHead: Int = 0
  var queuedBytes: Int = 0
  var draining: Bool = false
  var writeStartNs: Long = 0i64
  var lastRxNs: Long = 0i64
  var closingAtNs: Long = 0i64
  var released: Bool = false
  var aborted: Bool = false
  var abortCode: Int = 0
  var abortReason: String = ""
}

// Locked to allocate sequential registry handles atomically.
ref record HandleCounter {
  var next: Int = 0
}

val handleCounter: HandleCounter = HandleCounter()

val handleCounterLock: WsLock = newWsLock()

// Explicit type arguments: the JVM monomorphiser cannot infer a no-argument
// generic call at a module-level binding.
val registryMap: ConcurrentDict[Int, RegistryMeta] = newConcurrentDict[Int, RegistryMeta]()

val connMap: ConcurrentDict[String, ConnState] = newConcurrentDict[String, ConnState]()

func connKey(registryHandle: in Int, connectionId: in String): String {
  return registryHandle.toString() + ":" + connectionId
}

func emptyBytesVal(): slice[Byte] {
  val e: slice[Byte] = []
  e
}

func appendBytesToList(acc: in List[Byte], bytes: in slice[Byte]): Unit {
  var i = 0
  while i < bytes.length {
    acc.add(bytes[i])
    i = i + 1
  }
}

// `Std.TcpHost.hostListen` binds an IP literal, not a DNS name. Map the
// common non-literal binds the ecosystem's HTTP servers accept (`_kernel/
// http_server.l`'s `resolveBindHost`) so `Ws.startServer("0.0.0.0", ...)` —
// the module header's own example — and `"localhost"`/`"*"`/`"+"` all work.
func resolveBindHost(host: in String): String {
  if host == "*" or host == "+" {
    "0.0.0.0"
  } else if host == "localhost" {
    "127.0.0.1"
  } else {
    host
  }
}

// Read the ping-keepalive interval from the env var `ws.l`'s own module
// header documents (`LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS`, default
// 30000ms — see this file's header for why it's read here rather than
// threaded through `startServer`'s parameters). A non-numeric or negative
// value falls back to the documented default; `0` disables pings.
func resolvePingIntervalMs(): Int {
  val raw = getVarOrDefault("LYRIC_CONFIG_WS_SERVER_PINGINTERVALMS", "30000")
  match parseOptInt(raw) {
    case Some(v) -> if v >= 0 { v } else { 30000 }
    case None -> 30000
  }
}

// registerConnection stores the live transport connection under the
// registry's bookkeeping, returning the (shared, mutable) ConnState the
// caller uses for the connection's lifetime — no repeated dict lookup
// needed by the read/ping loops, which hold this same reference.
func registerConnection(registryHandle: in Int, connectionId: in String, conn: in Conn): Result[ConnState, String]
  requires: connectionId.length > 0
{
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, registryHandle, meta) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  val state = ConnState(
    isOpen = true,
    closing = false,
    conn = Some(conn),
    handle = registryHandle,
    connId = connectionId,
    maxOutboundBytes = meta.limits.maxOutboundBytes,
    lastRxNs = monotonicNanos()
  )
  val key = connKey(registryHandle, connectionId)
  if not cdTryAdd(connMap, key, state) {
    return Err("connection '" + connectionId + "' already registered")
  }
  lockEnter(meta.lock)
  defer {
    lockExit(meta.lock)
  }
  meta.openCount = meta.openCount + 1
  meta.connIds.add(connectionId)
  Ok(value = state)
}

// Close a single connection's bookkeeping state under its own lock (does
// NOT touch the socket or the registry's connIds list). Returns true if the
// connection was open (caller decrements the registry open count).
func tryCloseConn(state: in ConnState): Bool {
  lockEnter(state.lock)
  defer {
    lockExit(state.lock)
  }
  if state.isOpen {
    state.isOpen = false
    return true
  }
  false
}

func decrementOpenCount(handle: in Int): Unit {
  var meta: RegistryMeta = default()
  if cdTryGetValue(registryMap, handle, meta) {
    lockEnter(meta.lock)
    defer {
      lockExit(meta.lock)
    }
    if meta.openCount > 0 {
      meta.openCount = meta.openCount - 1
    }
  }
}

func removeConnIdFromMeta(handle: in Int, connectionId: in String): Unit {
  var meta: RegistryMeta = default()
  if cdTryGetValue(registryMap, handle, meta) {
    lockEnter(meta.lock)
    defer {
      lockExit(meta.lock)
    }
    var idx = 0 - 1
    var i = 0
    while i < meta.connIds.count {
      if meta.connIds[i] == connectionId {
        idx = i
      }
      i = i + 1
    }
    if idx >= 0 {
      meta.connIds.removeAt(idx)
    }
  }
}

// A point-in-time copy of a registry's live connection ids, taken under its
// lock so `broadcast` iterates a stable snapshot rather than the live
// (concurrently mutable) list.
func snapshotConnIds(meta: in RegistryMeta): List[String] {
  lockEnter(meta.lock)
  defer {
    lockExit(meta.lock)
  }
  val copy: List[String] = newList()
  var i = 0
  while i < meta.connIds.count {
    copy.add(meta.connIds[i])
    i = i + 1
  }
  copy
}

func invokeOnOpen(
  handle: in Int,
  connId: in String,
  path: in String,
  query: in String,
  remoteAddress: in String,
  headers: in Map[String, String],
): Unit {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    return
  }
  match meta.onOpen {
    case Some(cb) -> {
      match guardOnOpen(cb, connId, path, query, remoteAddress, headers) {
        case Some(message) -> reportHandlerFailure(handle, connId, "onOpen", message)
        case None -> ()
      }
    }
    case None -> ()
  }
}

func invokeOnMessage(handle: in Int, connId: in String, msgType: in String, data: in String): Unit {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    return
  }
  match meta.onMessage {
    case Some(cb) -> {
      match guardOnMessage(cb, connId, msgType, data) {
        case Some(message) -> reportHandlerFailure(handle, connId, "onMessage", message)
        case None -> ()
      }
    }
    case None -> ()
  }
}

func invokeOnClose(handle: in Int, connId: in String, code: in Int, reason: in String): Unit {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    return
  }
  match meta.onClose {
    case Some(cb) -> {
      match guardOnClose(cb, connId, code, reason) {
        case Some(message) -> reportHandlerFailure(handle, connId, "onClose", message)
        case None -> ()
      }
    }
    case None -> ()
  }
}

// A handler callback that throws must not end the connection's read loop
// unobserved: the failure is reported through `onError` and the connection
// carries on.  An `onError` that throws as well is written to stderr, the
// only place left to report it.  (The `guard*` calls, in `ws_prims.l`, turn a
// thrown failure into a message; on `--target native` there is no unwinding,
// so a handler's `panic` ends the process, as any native panic does.)
func reportHandlerFailure(handle: in Int, connId: in String, stage: in String, message: in String): Unit {
  val text = "the " + stage + " handler failed: " + message
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    return
  }
  match meta.onError {
    case Some(cb) -> {
      match guardOnError(cb, connId, text) {
        case Some(second) -> Console.error(
          "lyric-ws: connection " + connId + ": " + text + "; the onError handler also failed: " +
            second
        )
        case None -> ()
      }
    }
    case None -> ()
  }
}

func invokeOnError(handle: in Int, connId: in String, message: in String): Unit {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    return
  }
  match meta.onError {
    case Some(cb) -> cb(connId, message)
    case None -> ()
  }
}

@stable(since = "0.1")
pub func createRegistry(maxMessageSizeBytes: in Int, pingIntervalMs: in Int): Result[Int, String]
  requires: maxMessageSizeBytes >= 1024
  requires: pingIntervalMs >= 0
{
  if maxMessageSizeBytes < 1024 {
    return Err("createRegistry: maxMessageSizeBytes must be >= 1024")
  }
  if pingIntervalMs < 0 {
    return Err("createRegistry: pingIntervalMs must be >= 0")
  }
  lockEnter(handleCounterLock)
  handleCounter.next = handleCounter.next + 1
  val handle: Int = handleCounter.next
  lockExit(handleCounterLock)
  val meta = RegistryMeta(maxMessageSizeBytes = maxMessageSizeBytes, pingIntervalMs = pingIntervalMs, openCount = 0)
  val _ = cdTryAdd(registryMap, handle, meta)
  Ok(handle)
}

// ─── Per-connection write path (data, ping, close) ────────────────────────────
// Every outbound frame goes through `enqueueFrame`; `drainQueue` is the only
// code that writes to the socket after the upgrade, one frame at a time, so
// frames never interleave and a stalled peer blocks only its own drain task.
func nanosToMs(ns: in Long): Long {
  ns / 1000000i64
}

// Shut the socket down and stop queueing (a slow consumer, a stalled write, a
// failed write). The read loop sees the shutdown as an end of stream and runs
// the normal teardown. `report` also tells `onError`. Never touches a socket
// whose owner has released it.
func abortConnection(state: in ConnState, conn: in Conn, code: in Int, reason: in String, report: in Bool): Unit {
  var first = false
  lockEnter(state.lock)
  if not state.aborted {
    state.aborted = true
    state.closing = true
    state.abortCode = code
    state.abortReason = reason
    state.queue.clear()
    state.queueHead = 0
    state.queuedBytes = 0
    first = true
    if not state.released {
      hostShutdown(conn)
    }
  }
  lockExit(state.lock)
  if first and report {
    invokeOnError(state.handle, state.connId, reason)
  }
}

// Writes the queue out, one frame at a time, until it is empty. Started by
// `enqueueFrame` (`draining` already set) and run on its own task.
func drainQueue(state: in ConnState, conn: in Conn): Unit {
  var running = true
  while running {
    var frame = emptyBytesVal()
    var have = false
    lockEnter(state.lock)
    if state.aborted or state.queueHead >= state.queue.count {
      state.queue.clear()
      state.queueHead = 0
      state.queuedBytes = 0
      state.draining = false
      running = false
    } else {
      frame = state.queue[state.queueHead]
      state.queueHead = state.queueHead + 1
      state.writeStartNs = monotonicNanos()
      have = true
    }
    lockExit(state.lock)
    if have {
      val outcome = hostWrite(conn, frame)
      lockEnter(state.lock)
      state.writeStartNs = 0i64
      if not state.aborted {
        state.queuedBytes = state.queuedBytes - frame.length
        if state.queuedBytes < 0 {
          state.queuedBytes = 0
        }
      }
      lockExit(state.lock)
      match outcome {
        case Ok(_) -> ()
        case Err(e) -> abortConnection(state, conn, 1006, "write failed: " + TcpError.message(e), false)
      }
    }
  }
}

// Queue one encoded frame. `control` frames (ping, pong, close) are exempt
// from the backlog bound. Returns once queued, never after the socket write.
func enqueueFrame(state: in ConnState, conn: in Conn, frame: in slice[Byte], control: in Bool): Result[Unit, String] {
  var start = false
  var failure = ""
  var overflow = false
  lockEnter(state.lock)
  if not state.isOpen or state.aborted {
    failure = "connection is closed"
  } else if state.closing and not control {
    failure = "connection is closing"
  } else if not control and state.queuedBytes > 0 and state.queuedBytes + frame.length > state.maxOutboundBytes {
    overflow = true
  } else {
    state.queue.add(frame)
    state.queuedBytes = state.queuedBytes + frame.length
    if not state.draining {
      state.draining = true
      start = true
    }
  }
  lockExit(state.lock)
  if overflow {
    val reason = "slow consumer: more than " + state.maxOutboundBytes.toString() + " bytes are waiting to be sent"
    abortConnection(state, conn, 1008, reason, true)
    return Err(error = reason)
  }
  if failure.length > 0 {
    return Err(error = failure)
  }
  if start {
    runBackground({ -> drainQueue(state, conn) })
  }
  Ok(value = ())
}

// Send a Close frame exactly once per connection: the first caller (whether
// the read loop echoing a peer-initiated close, or an application `close`/
// `send(..., "close", ...)` call) queues it and flips `closing`; every
// subsequent caller is a no-op. The flag is taken under the connection lock,
// so two racing closers can't both observe "not yet closing".
func sendCloseIfNotAlready(state: in ConnState, conn: in Conn, code: in Int, reason: in String): Unit {
  var first = false
  lockEnter(state.lock)
  if not state.closing {
    state.closing = true
    state.closingAtNs = monotonicNanos()
    first = true
  }
  lockExit(state.lock)
  if first {
    val _ = enqueueFrame(state, conn, encodeCloseReply(code, reason), true);
    ()
  }
}

// Blocks until the drain task has written everything queued, so a Close reply
// is on the wire before the socket is released. A drain that does not finish
// within `maxMs` has its socket shut down (the write then fails at once), and
// the wait carries on until the task has ended: the socket must not be
// released under it.
func waitDrained(state: in ConnState, conn: in Conn, maxMs: in Int): Unit {
  var waited = 0
  var forced = false
  var busy = true
  while busy {
    lockEnter(state.lock)
    busy = state.draining
    lockExit(state.lock)
    if busy {
      if waited >= maxMs and not forced {
        forced = true
        abortConnection(state, conn, 1006, "close timed out with frames still queued", false)
      }
      threadSleep(1)
      waited = waited + 1
    }
  }
}

func frameFor(messageType: in String, data: in String): Result[slice[Byte], String] {
  if messageType == "text" {
    Ok(value = encodeText(encodeUtf8(data)))
  } else if messageType == "binary" {
    match tryDecodeBase64(data) {
      case Some(bytes) -> Ok(value = encodeBinary(bytes))
      case None -> Err(error = "invalid base64 payload for binary frame")
    }
  } else if messageType == "ping" {
    Ok(value = encodePing(emptyBytesVal()))
  } else if messageType == "pong" {
    Ok(value = encodePong(emptyBytesVal()))
  } else {
    Err(error = "unknown message type '" + messageType + "'")
  }
}

func writeMessage(state: in ConnState, conn: in Conn, messageType: in String, data: in String): Result[Unit, String] {
  if messageType == "close" {
    sendCloseIfNotAlready(state, conn, 1000, data)
    Ok(())
  } else {
    match frameFor(messageType, data) {
      case Ok(frame) -> enqueueFrame(state, conn, frame, messageType != "text" and messageType != "binary")
      case Err(e) -> Err(error = e)
    }
  }
}

// ─── Handshake ─────────────────────────────────────────────────────────────────
// Maximum bytes accumulated while looking for the handshake's terminating
// blank line before giving up — a generous bound for real HTTP headers,
// small enough that a peer that never sends one can't grow this buffer
// without limit.
val maxHandshakeBytes: Int = 16384

func performHandshake(
  conn: in Conn,
  expectedPath: in String,
  allowedOrigins: in slice[String],
  sameHostPorts: in slice[Int],
): Result[HandshakeResult, String] {
  val acc: List[Byte] = newList()
  var found = false
  var attempts = 0
  while not found and attempts < 256 {
    match hostRead(conn, 4096) {
      case Err(e) -> return Err(error = TcpError.message(e))
      case Ok(bytes) -> {
        if bytes.length == 0 {
          return Err(error = "connection closed during handshake read")
        }
        appendBytesToList(acc, bytes)
      }
    }
    if acc.count > maxHandshakeBytes {
      return Err(error = "handshake request exceeds the maximum header size")
    }
    match findHeaderTerminator(acc.toArray()) {
      case Some(_) -> {
        found = true
      }
      case None -> ()
    }
    attempts = attempts + 1
  }
  if not found {
    return Err(error = "handshake did not complete a header block within the read budget")
  }
  match parseHandshakeRequest(acc.toArray()) {
    case Err(msg) -> {
      val _ = hostWrite(conn, buildRejectResponse(400, "Bad Request"))
      Err(error = msg)
    }
    case Ok(result) -> {
      if result.request.path != expectedPath {
        val _ = hostWrite(conn, buildRejectResponse(404, "Not Found"))
        Err(error = "path mismatch: expected '" + expectedPath + "', got '" + result.request.path + "'")
      } else if not requestOriginAllowedFor(result.request, allowedOrigins, sameHostPorts) {
        // Cross-site WebSocket hijacking defence (#7243): refused before the
        // upgrade, so the page's cookies never reach an open socket.
        val _ = hostWrite(conn, buildRejectResponse(403, "Forbidden"))
        Err(error = "origin not allowed")
      } else {
        match hostWrite(conn, buildAcceptResponse(result.request.secWebSocketKey)) {
          case Ok(_) -> Ok(value = result)
          case Err(e) -> Err(error = TcpError.message(e))
        }
      }
    }
  }
}

// ─── Per-connection read loop ──────────────────────────────────────────────────
func deliverMessage(handle: in Int, connId: in String, isText: in Bool, payload: in slice[Byte]): Unit {
  if isText {
    match tryDecodeUtf8(payload) {
      case Some(text) -> invokeOnMessage(handle, connId, "text", text)
      // Unreachable: Ws.Frame already validates UTF-8 before emitting a text
      // FeMessage event.
      case None -> ()
    }
  } else {
    invokeOnMessage(handle, connId, "binary", encodeBase64(payload))
  }
}

record ReadLoopResult {
  code: Int
  reason: String
}

func runReadLoop(
  handle: in Int,
  connId: in String,
  state: in ConnState,
  conn: in Conn,
  maxMessageSizeBytes: in Int,
  initialBytes: in slice[Byte],
): ReadLoopResult {
  var decoder = newFrameDecoder(maxMessageSizeBytes)
  // 1006 (Abnormal Closure) is RFC 6455's reserved code for "the transport
  // dropped with no Close frame ever exchanged" — the fallback if the loop
  // ends via EOF/read error rather than a FeClose/FeProtocolError event.
  var finalCode = 1006
  var finalReason = ""
  var running = true
  var pendingInitial = true
  while running {
    var bytes = emptyBytesVal()
    if pendingInitial {
      pendingInitial = false
      bytes = initialBytes
    } else {
      match hostRead(conn, 65536) {
        case Err(_) -> {
          running = false
        }
        case Ok(b) -> {
          if b.length == 0 {
            running = false
          } else {
            bytes = b
            lockEnter(state.lock)
            state.lastRxNs = monotonicNanos()
            lockExit(state.lock)
          }
        }
      }
    }
    if running {
      val result = feedFrames(decoder, bytes)
      decoder = result.state
      var i = 0
      while i < result.events.count {
        match result.events[i] {
          case FeMessage(isText, payload) -> deliverMessage(handle, connId, isText, payload)
          case FePing(_) -> invokeOnMessage(handle, connId, "ping", "")
          case FePong(_) -> invokeOnMessage(handle, connId, "pong", "")
          case FeClose(code, reason) -> {
            finalCode = code
            finalReason = reason
            sendCloseIfNotAlready(state, conn, code, reason)
            running = false
          }
          case FeProtocolError(message) -> {
            finalCode = 1002
            finalReason = message
            sendCloseIfNotAlready(state, conn, 1002, message)
            invokeOnError(handle, connId, message)
            running = false
          }
        }
        i = i + 1
      }
      if isFrameDecoderFailed(decoder) {
        running = false
      }
    }
  }
  ReadLoopResult(code = finalCode, reason = finalReason)
}

func finishConnection(
  handle: in Int,
  connId: in String,
  state: in ConnState,
  conn: in Conn,
  code: in Int,
  reason: in String,
): Unit {
  val wasOpen = tryCloseConn(state)
  if wasOpen {
    decrementOpenCount(handle)
  }
  removeConnIdFromMeta(handle, connId)
  var removed: ConnState = default()
  val _ = cdTryRemove(connMap, connKey(handle, connId), removed)
  waitDrained(state, conn, closeHandshakeTimeoutMs)
  var reportCode = code
  var reportReason = reason
  lockEnter(state.lock)
  state.released = true
  if code == 1006 and state.abortCode != 0 {
    reportCode = state.abortCode
    reportReason = state.abortReason
  }
  lockExit(state.lock)
  releaseWsLock(state.lock)
  hostClose(conn)
  if wasOpen {
    invokeOnClose(handle, connId, reportCode, reportReason)
  }
}

// ─── Maintenance: keepalive, idle timeout, write timeout ──────────────────────
// How often the maintenance task wakes: a quarter of the shortest period it
// enforces, bounded so a thousand connections do not wake more than about a
// thousand times a second in total.
func maintenanceTickMs(pingIntervalMs: in Int, limits: in ServerLimits): Int {
  var shortest = 4000
  if pingIntervalMs > 0 and pingIntervalMs < shortest {
    shortest = pingIntervalMs
  }
  if limits.idleTimeoutMs > 0 and limits.idleTimeoutMs < shortest {
    shortest = limits.idleTimeoutMs
  }
  if limits.writeTimeoutMs > 0 and limits.writeTimeoutMs < shortest {
    shortest = limits.writeTimeoutMs
  }
  val quarter = shortest / 4
  if quarter < 10 {
    10
  } else if quarter > 1000 {
    1000
  } else {
    quarter
  }
}

// One task per connection for its whole life. It
//   * aborts a connection whose write in flight has made no progress for
//     `writeTimeoutMs` (the peer stopped reading: the slow-consumer case a
//     queue alone cannot bound, because one frame can be large);
//   * shuts down a connection whose Close frame the peer never answered
//     within `closeHandshakeTimeoutMs`;
//   * starts the close handshake (1001) on a connection that has received
//     nothing, not even a Pong, for `idleTimeoutMs`;
//   * queues a Ping every `pingIntervalMs` when the queue is empty.
func runMaintenanceLoop(state: in ConnState, conn: in Conn, pingIntervalMs: in Int, limits: in ServerLimits): Unit {
  val tickMs = maintenanceTickMs(pingIntervalMs, limits)
  var lastPingNs = monotonicNanos()
  var running = true
  while running {
    threadSleep(tickMs)
    val now = monotonicNanos()
    lockEnter(state.lock)
    val open = state.isOpen and not state.aborted
    val closing = state.closing
    val writeStartNs = state.writeStartNs
    val lastRxNs = state.lastRxNs
    val closingAtNs = state.closingAtNs
    val idleQueue = state.queuedBytes == 0
    lockExit(state.lock)
    if not open {
      running = false
    } else if limits.writeTimeoutMs > 0 and writeStartNs != 0i64 and nanosToMs(now - writeStartNs) > limits.writeTimeoutMs.toLong() {
      abortConnection(
        state,
        conn,
        1008,
        "slow consumer: a write made no progress for " + limits.writeTimeoutMs.toString() + " ms",
        true
      )
    } else if closing and closingAtNs != 0i64 and nanosToMs(now - closingAtNs) > closeHandshakeTimeoutMs.toLong() {
      abortConnection(state, conn, 1006, "the peer did not answer the Close frame", false)
    } else if not closing and limits.idleTimeoutMs > 0 and nanosToMs(now - lastRxNs) > limits.idleTimeoutMs.toLong() {
      lockEnter(state.lock)
      state.abortCode = 1001
      state.abortReason = "idle timeout: nothing received for " + limits.idleTimeoutMs.toString() + " ms"
      lockExit(state.lock)
      sendCloseIfNotAlready(state, conn, 1001, "idle timeout")
    } else if not closing and pingIntervalMs > 0 and idleQueue and nanosToMs(now - lastPingNs) >= pingIntervalMs.toLong() {
      lastPingNs = now
      val _ = enqueueFrame(state, conn, encodePing(emptyBytesVal()), true);
      ()
    }
  }
}

// ─── Connection lifecycle ───────────────────────────────────────────────────────
// Reserve a connection slot, or say the server is full. Slots are counted from
// accept to close, handshake included, so a peer that never completes one still
// holds its slot until `handshakeTimeoutMs` closes it.
func admitConnection(meta: in RegistryMeta): Bool {
  var max = meta.limits.maxConnections
  if max == 0 {
    max = Hsh.defaultMaxConnections()
  }
  lockEnter(meta.lock)
  defer {
    lockExit(meta.lock)
  }
  if meta.liveConnections >= max {
    return false
  }
  meta.liveConnections = meta.liveConnections + 1
  true
}

func releaseConnectionSlot(handle: in Int): Unit {
  var meta: RegistryMeta = default()
  if cdTryGetValue(registryMap, handle, meta) {
    lockEnter(meta.lock)
    defer {
      lockExit(meta.lock)
    }
    if meta.liveConnections > 0 {
      meta.liveConnections = meta.liveConnections - 1
    }
  }
}

// The accepted connection is over the cap: say so (a plain connection only: a
// TLS peer has not shaken hands yet) and close it.
func rejectOverCap(conn: in Conn, plain: in Bool): Unit {
  if plain {
    hostSetIoTimeout(conn, 2000)
    val _ = hostWrite(conn, buildRejectResponse(503, "Service Unavailable"));
    ()
  }
  hostClose(conn)
}

// Finish the TLS handshake of an accepted connection, bounded by the
// handshake timeout, tracking it so `stopServer` releases the prepared TLS
// state only once no handshake is using it.
func upgradeTls(meta: in RegistryMeta, plain: in Conn): Result[Conn, String] {
  match meta.tls {
    case None -> Ok(value = plain)
    case Some(tls) -> {
      lockEnter(meta.lock)
      meta.upgrading = meta.upgrading + 1
      lockExit(meta.lock)
      val outcome = hostUpgradeServerTlsPrepared(plain, tls, meta.limits.handshakeTimeoutMs)
      lockEnter(meta.lock)
      meta.upgrading = meta.upgrading - 1
      val releaseNow = meta.stopped and meta.upgrading == 0
      lockExit(meta.lock)
      if releaseNow {
        hostReleaseServerTls(tls)
      }
      match outcome {
        case Ok(c) -> Ok(value = c)
        case Err(e) -> {
          hostClose(plain)
          Err(error = TcpError.message(e))
        }
      }
    }
  }
}

func handleConnection(
  handle: in Int,
  accepted: in Conn,
  admitted: in Bool,
  expectedPath: in String,
  allowedOrigins: in slice[String],
  sameHostPorts: in slice[Int],
): Unit {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    hostClose(accepted)
    return
  }
  if not admitted {
    rejectOverCap(accepted, isNone(meta.tls))
    return
  }
  serveAdmitted(meta, handle, accepted, expectedPath, allowedOrigins, sameHostPorts)
  releaseConnectionSlot(handle)
}

func serveAdmitted(
  meta: in RegistryMeta,
  handle: in Int,
  accepted: in Conn,
  expectedPath: in String,
  allowedOrigins: in slice[String],
  sameHostPorts: in slice[Int],
): Unit {
  match upgradeTls(meta, accepted) {
    case Err(_) -> ()
    case Ok(conn) -> {
      if meta.limits.handshakeTimeoutMs > 0 {
        hostSetIoTimeout(conn, meta.limits.handshakeTimeoutMs)
      }
      match performHandshake(conn, expectedPath, allowedOrigins, sameHostPorts) {
        case Err(_) -> hostClose(conn)
        case Ok(hsResult) -> {
          hostSetIoTimeout(conn, 0)
          serveUpgraded(handle, conn, hsResult.request, hsResult.leftover)
        }
      }
    }
  }
}

// Run an upgraded connection (the `101` already written) until it closes.
func serveUpgraded(handle: in Int, conn: in Conn, request: in HandshakeRequest, leftover: in slice[Byte]): Unit {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    hostClose(conn)
    return
  }
  val connId = uuidToString(newUuid())
  match registerConnection(handle, connId, conn) {
    case Err(_) -> hostClose(conn)
    case Ok(state) -> {
      val remoteAddress = hostRemoteAddress(conn)
      invokeOnOpen(handle, connId, request.path, request.query, remoteAddress, request.headers)
      val limits = meta.limits
      val pingIntervalMs = meta.pingIntervalMs
      runBackground({ -> runMaintenanceLoop(state, conn, pingIntervalMs, limits) })
      val outcome = runReadLoop(handle, connId, state, conn, meta.maxMessageSizeBytes, leftover)
      finishConnection(handle, connId, state, conn, outcome.code, outcome.reason)
    }
  }
}

// Validate an upgrade request another server parsed and, if it passes,
// answer `101` and serve the connection; otherwise answer the matching
// rejection status. Always leaves `conn` closed or owned by the read loop.
func adoptUpgrade(
  handle: in Int,
  conn: in Conn,
  target: in String,
  headers: in Map[String, String],
  expectedPath: in String,
  allowedOrigins: in slice[String],
  sameHostPorts: in slice[Int],
): Unit {
  // The HTTP server bounded reads by its idle timeout; a WebSocket is
  // long-lived and relies on ping keepalive instead, as with `startServer`.
  hostSetIoTimeout(conn, 0)
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    val _ = hostWrite(conn, buildRejectResponse(503, "Service Unavailable"))
    hostClose(conn)
    return
  }
  if not admitConnection(meta) {
    val _ = hostWrite(conn, buildRejectResponse(503, "Service Unavailable"))
    hostClose(conn)
    return
  }
  match validateUpgradeRequest(target, headers) {
    case Err(_) -> {
      val _ = hostWrite(conn, buildRejectResponse(400, "Bad Request"))
      hostClose(conn)
    }
    case Ok(request) -> {
      if request.path != expectedPath {
        val _ = hostWrite(conn, buildRejectResponse(404, "Not Found"))
        hostClose(conn)
      } else if not requestOriginAllowedFor(request, allowedOrigins, sameHostPorts) {
        // Cross-site WebSocket hijacking defence (#7243), as in
        // `performHandshake`.
        val _ = hostWrite(conn, buildRejectResponse(403, "Forbidden"))
        hostClose(conn)
      } else {
        match hostWrite(conn, buildAcceptResponse(request.secWebSocketKey)) {
          case Err(_) -> hostClose(conn)
          case Ok(_) -> serveUpgraded(handle, conn, request, emptyBytesVal())
        }
      }
    }
  }
  releaseConnectionSlot(handle)
}

func wsAcceptLoop(
  handle: in Int,
  transport: in Listener,
  path: in String,
  allowedOrigins: in slice[String],
  sameHostPorts: in slice[Int],
): Unit {
  var running = true
  while running {
    match hostAccept(transport) {
      case Ok(conn) -> {
        var meta: RegistryMeta = default()
        var admitted = false
        if cdTryGetValue(registryMap, handle, meta) {
          admitted = admitConnection(meta)
        }
        runBackground({ -> handleConnection(handle, conn, admitted, path, allowedOrigins, sameHostPorts) })
      }
      case Err(e) -> {
        if not acceptShouldContinue(e) {
          running = false
        }
      }
    }
  }
}

// ─── Public kernel surface ──────────────────────────────────────────────────────
/// Start a real WebSocket server: binds `host:port`, upgrades exactly `path`
/// to WebSocket (RFC 6455), and invokes the given callbacks for the
/// connection lifecycle. See the module header for the concurrency model and
/// the `pingIntervalMs` note. Plain TCP, `defaultLimits()`.
@stable(since = "0.1")
pub func startServer(
  host: in String,
  port: in Int,
  path: in String,
  maxMessageSizeBytes: in Int,
  allowedOrigins: in slice[String],
  sameHostPorts: in slice[Int],
  onOpen: in (String, String, String, String, Map[String, String]) -> Unit,
  onMessage: in (String, String, String) -> Unit,
  onClose: in (String, Int, String) -> Unit,
  onError: in (String, String) -> Unit,
): Result[Int, String]
  requires: host.length > 0
  requires: port >= 1 and port <= 65535
  requires: path.length > 0
  requires: maxMessageSizeBytes >= 1024
{
  startServerWith(
    host,
    port,
    path,
    maxMessageSizeBytes,
    allowedOrigins,
    sameHostPorts,
    defaultLimits(),
    None,
    onOpen,
    onMessage,
    onClose,
    onError
  )
}

/// As `startServer`, with explicit limits and, when `tls` is given, a `wss`
/// listener: each accepted connection completes a TLS handshake (bounded by
/// `limits.handshakeTimeoutMs`) before the WebSocket upgrade, on the
/// connection's own task, so a peer that stalls its handshake holds nothing
/// but its own slot. The configuration is validated and compiled once, before
/// the port is bound.
@stable(since = "0.4")
pub func startServerWith(
  host: in String,
  port: in Int,
  path: in String,
  maxMessageSizeBytes: in Int,
  allowedOrigins: in slice[String],
  sameHostPorts: in slice[Int],
  limits: in ServerLimits,
  tls: in Option[TlsServerConfig],
  onOpen: in (String, String, String, String, Map[String, String]) -> Unit,
  onMessage: in (String, String, String) -> Unit,
  onClose: in (String, Int, String) -> Unit,
  onError: in (String, String) -> Unit,
): Result[Int, String]
  requires: host.length > 0
  requires: port >= 1 and port <= 65535
  requires: path.length > 0
  requires: maxMessageSizeBytes >= 1024
{
  val pingIntervalMs = resolvePingIntervalMs()
  var prepared: Option[ServerTls] = None
  match tls {
    case None -> ()
    case Some(cfg) -> match hostPrepareServerTls(cfg) {
      case Err(e) -> return Err(error = TcpError.message(e))
      case Ok(t) -> {
        prepared = Some(value = t)
      }
    }
  }
  var cap = limits.maxConnections
  if cap == 0 {
    cap = Hsh.defaultMaxConnections()
  }
  ensureThreadCapacity()
  match hostListen(resolveBindHost(host), port) {
    case Err(e) -> {
      match prepared {
        case Some(t) -> hostReleaseServerTls(t)
        case None -> ()
      }
      Err(error = TcpError.message(e))
    }
    case Ok(transport) -> {
      lockEnter(handleCounterLock)
      handleCounter.next = handleCounter.next + 1
      val handle: Int = handleCounter.next
      lockExit(handleCounterLock)
      val meta = RegistryMeta(
        maxMessageSizeBytes = maxMessageSizeBytes,
        pingIntervalMs = pingIntervalMs,
        openCount = 0,
        onOpen = Some(onOpen),
        onMessage = Some(onMessage),
        onClose = Some(onClose),
        onError = Some(onError),
        listener = Some(transport),
        limits = limits,
        tls = prepared
      )
      if not cdTryAdd(registryMap, handle, meta) {
        hostStopListener(transport)
        return Err(error = "registry handle collision (unreachable)")
      }
      runBackground({ -> wsAcceptLoop(handle, transport, path, allowedOrigins, sameHostPorts) })
      Ok(value = handle)
    }
  }
}

/// Create a WebSocket endpoint with no listener of its own:
/// connections reach it through `adoptConnection`, called by an HTTP server
/// that received the upgrade request on its own port. Returns a registry
/// handle usable with `send`/`broadcast`/`close`/`connectionCount`/
/// `isConnected`, exactly like `startServer`'s. The callbacks are those of
/// `startServer`.
@stable(since = "0.3")
pub func createEndpoint(
  maxMessageSizeBytes: in Int,
  onOpen: in (String, String, String, String, Map[String, String]) -> Unit,
  onMessage: in (String, String, String) -> Unit,
  onClose: in (String, Int, String) -> Unit,
  onError: in (String, String) -> Unit,
): Result[Int, String]
  requires: maxMessageSizeBytes >= 1024
{
  createEndpointWith(maxMessageSizeBytes, defaultLimits(), onOpen, onMessage, onClose, onError)
}

/// As `createEndpoint`, with explicit limits (`handshakeTimeoutMs` does not
/// apply: the HTTP server that adopts the connection has read the request).
@stable(since = "0.4")
pub func createEndpointWith(
  maxMessageSizeBytes: in Int,
  limits: in ServerLimits,
  onOpen: in (String, String, String, String, Map[String, String]) -> Unit,
  onMessage: in (String, String, String) -> Unit,
  onClose: in (String, Int, String) -> Unit,
  onError: in (String, String) -> Unit,
): Result[Int, String]
  requires: maxMessageSizeBytes >= 1024
{
  ensureThreadCapacity()
  lockEnter(handleCounterLock)
  handleCounter.next = handleCounter.next + 1
  val handle: Int = handleCounter.next
  lockExit(handleCounterLock)
  val noListener: Option[Listener] = None
  val meta = RegistryMeta(
    maxMessageSizeBytes = maxMessageSizeBytes,
    pingIntervalMs = resolvePingIntervalMs(),
    openCount = 0,
    onOpen = Some(onOpen),
    onMessage = Some(onMessage),
    onClose = Some(onClose),
    onError = Some(onError),
    listener = noListener,
    limits = limits
  )
  if not cdTryAdd(registryMap, handle, meta) {
    return Err(error = "registry handle collision (unreachable)")
  }
  Ok(value = handle)
}

/// Hand an HTTP/1.1 connection carrying a WebSocket upgrade request to the
/// endpoint `registryHandle` (from `createEndpoint`). The caller has read the
/// request (`GET` over HTTP/1.1, no bytes after it) but written nothing;
/// `target` is its raw request target and `headers` its header fields.
/// Returns at once: validation, the `101` (or a `400`/`403`/`404`/`503`
/// rejection) and the connection's read loop run on a background task,
/// which owns and eventually closes `conn`. `expectedPath`,
/// `allowedOrigins` and `sameHostPorts` apply as in `startServer`.
@stable(since = "0.3")
pub func adoptConnection(
  registryHandle: in Int,
  // Qualified so the restored-package contract of `Ws.dll` resolves it
  // (a bare stdlib name outside `Std.Core` does not survive synthesis).
  conn: in Std.TcpHost.Conn,
  target: in String,
  headers: in Map[String, String],
  expectedPath: in String,
  allowedOrigins: in slice[String],
  sameHostPorts: in slice[Int],
): Unit {
  runBackground({ -> adoptUpgrade(registryHandle, conn, target, headers, expectedPath, allowedOrigins, sameHostPorts) });
  ()
}

/// Stop a server started by `startServer`. In-flight connections finish
/// their current frame; the accept loop ends once the stopped listener's
/// next accept fails. A `wss` server's prepared TLS state is released once no
/// handshake is using it.
@stable(since = "0.1")
pub func stopServer(registryHandle: in Int): Result[Unit, String] {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, registryHandle, meta) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  match meta.listener {
    case Some(transport) -> {
      hostStopListener(transport)
      lockEnter(meta.lock)
      val first = not meta.stopped
      meta.stopped = true
      val releaseNow = first and meta.upgrading == 0
      lockExit(meta.lock)
      if releaseNow {
        match meta.tls {
          case Some(t) -> hostReleaseServerTls(t)
          case None -> ()
        }
      }
      Ok(())
    }
    case None -> Err("registry " + registryHandle.toString() + " has no running server")
  }
}

/// Queue one message for a connection. `Ok` means the frame is queued, not
/// that the peer has it: a peer that stops reading is dropped (see the module
/// header) rather than blocking the caller.
@stable(since = "0.1")
pub func send(
  registryHandle: in Int, connectionId: in String, messageType: in String, data: in String
): Result[Unit, String]
  requires: connectionId.length > 0
  requires: messageType.length > 0
{
  val key = connKey(registryHandle, connectionId)
  var state: ConnState = default()
  if not cdTryGetValue(connMap, key, state) {
    return Err("unknown connection '" + connectionId + "'")
  }
  if not state.isOpen {
    return Err("connection '" + connectionId + "' is closed")
  }
  match state.conn {
    case None -> Err("connection '" + connectionId + "' has no live transport")
    case Some(conn) -> writeMessage(state, conn, messageType, data)
  }
}

/// Queue a message for every open connection, encoding it once. A connection
/// that cannot take it (closed meanwhile, or dropped as a slow consumer) does
/// not delay the others; the first such failure is the result.
@stable(since = "0.1")
pub func broadcast(registryHandle: in Int, messageType: in String, data: in String): Result[Unit, String]
  requires: messageType.length > 0
{
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, registryHandle, meta) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  val ids = snapshotConnIds(meta)
  var hasErr = false
  var firstErr = ""
  var frame = emptyBytesVal()
  var haveFrame = false
  if messageType != "close" {
    match frameFor(messageType, data) {
      case Ok(f) -> {
        frame = f
        haveFrame = true
      }
      case Err(e) -> return Err(error = e)
    }
  }
  val control = messageType != "text" and messageType != "binary"
  var i = 0
  while i < ids.count {
    var state: ConnState = default()
    if cdTryGetValue(connMap, connKey(registryHandle, ids[i]), state) {
      match state.conn {
        case None -> ()
        case Some(conn) -> {
          val outcome = if haveFrame {
            enqueueFrame(state, conn, frame, control)
          } else {
            writeMessage(state, conn, messageType, data)
          }
          match outcome {
            case Ok(_) -> ()
            case Err(e) -> {
              if not hasErr {
                hasErr = true
                firstErr = e
              }
            }
          }
        }
      }
    }
    i = i + 1
  }
  if hasErr {
    Err(firstErr)
  } else {
    Ok(())
  }
}

@stable(since = "0.1")
pub func close(registryHandle: in Int, connectionId: in String, code: in Int, reason: in String): Result[Unit, String]
  requires: connectionId.length > 0
{
  val key = connKey(registryHandle, connectionId)
  var state: ConnState = default()
  if not cdTryGetValue(connMap, key, state) {
    return Ok(())
  }
  match state.conn {
    case None -> Ok(())
    case Some(conn) -> {
      sendCloseIfNotAlready(state, conn, code, reason)
      Ok(())
    }
  }
}

@stable(since = "0.1")
pub func connectionCount(registryHandle: in Int): Int {
  var meta: RegistryMeta = default()
  if cdTryGetValue(registryMap, registryHandle, meta) {
    return meta.openCount
  }
  return 0
}

@stable(since = "0.1")
pub func isConnected(registryHandle: in Int, connectionId: in String): Bool
  requires: connectionId.length > 0
{
  val key = connKey(registryHandle, connectionId)
  var state: ConnState = default()
  if cdTryGetValue(connMap, key, state) {
    return state.isOpen
  }
  false
}

// ─── Rate limiter (token bucket) ─────────────────────────────────────────────
//
// One `Resilience.TokenBucket` per key: up to `messagesPerMinute + burstSize`
// messages at once, refilling at `messagesPerMinute` a minute.  It replaced a
// tumbling window whose burst budget never refilled and which allowed twice
// the rate across a window boundary (#7249, #1178).
ref record RateEntry {
  var scaledTokens: Long = 0i64
  var lastRefillMs: Long = 0i64
}

// Single global lock serialises all rate-limiter mutations.
val rateLock: WsLock = newWsLock()

val rateLimitMap: ConcurrentDict[String, RateEntry] = newConcurrentDict[String, RateEntry]()

@stable(since = "0.1")
pub func checkRateLimit(key: in String, messagesPerMinute: in Int, burstSize: in Int): Bool
  requires: key.length > 0
  requires: messagesPerMinute > 0
  requires: burstSize > 0
{
  val nowMs = nowEpochMillis()
  lockEnter(rateLock)
  defer {
    lockExit(rateLock)
  }

  val fullBucket = Resilience.newTokenBucket(messagesPerMinute, burstSize, nowMs)
  var re: RateEntry = default()
  if not cdTryGetValue(rateLimitMap, key, re) {
    val newEntry = RateEntry(scaledTokens = fullBucket.scaledTokens, lastRefillMs = fullBucket.lastRefillMs)
    val _ = cdTryAdd(rateLimitMap, key, newEntry)
    var re2: RateEntry = default()
    if cdTryGetValue(rateLimitMap, key, re2) {
      re = re2
    } else {
      re = newEntry
    }
  }

  val take = Resilience.takeToken(
    Resilience.TokenBucket(scaledTokens = re.scaledTokens, lastRefillMs = re.lastRefillMs),
    messagesPerMinute,
    burstSize,
    nowMs
  )
  re.scaledTokens = take.bucket.scaledTokens
  re.lastRefillMs = take.bucket.lastRefillMs
  take.allowed
}
