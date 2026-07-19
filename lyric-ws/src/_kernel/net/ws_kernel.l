//! Ws.Kernel.Net — dotnet WebSocket connection registry and real server
//! (docs/62-jsonrpc-mcp.md §6, #778).
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
//! third `Task` sending periodic Ping frames. Lyric `spawn`/`scope` is
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
//! Per-connection writes (data sends, pings, and the close handshake) are
//! all serialized through the connection's own monitor lock (`ConnState`)
//! so a ping keepalive and an application `send`/`close` call can never
//! interleave bytes on the same socket.
//!
//! Only active when compiled with feature = "dotnet".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package Ws.Kernel.Net

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Environment
import Std.Parse
import Std.Time
import Std.Uuid
import Std.TcpHost
import Ws.Frame
import Ws.Handshake

extern type ConcurrentDict[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDict[K, V](): ConcurrentDict[K, V] = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryRemove")
func cdTryRemove[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@axiom("System.Threading.Monitor.Enter — acquires an exclusive lock on obj")
@externStatic
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@axiom("System.Threading.Monitor.Exit — releases an exclusive lock on obj")
@externStatic
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

// `Task.Run(Action)` gives a background OS thread for the accept loop and
// each connection's read/ping loops — the same primitive `_kernel/
// http_server.l` uses, for the same reason (`spawn` is degenerate-
// synchronous on this target).
extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externStatic
@externTarget("System.Threading.Thread.Sleep")
func threadSleep(ms: in Int): Unit = ()

// ─── Connection registry ──────────────────────────────────────────────────────
record RegistryMeta {
  var maxMessageSizeBytes: Int = 1024
  var pingIntervalMs: Int = 0
  var openCount: Int = 0
  onOpen: Option[(String, String, String, String) -> Unit] = None
  onMessage: Option[(String, String, String) -> Unit] = None
  onClose: Option[(String, Int, String) -> Unit] = None
  onError: Option[(String, String) -> Unit] = None
  var listener: Option[Listener] = None
  connIds: List[String] = newList()
}

/// A single connection's live state. `conn` is `None` for a
/// bookkeeping-only entry (never populated by this file — kept `Option` for
/// symmetry with `RegistryMeta`'s callback fields and so `default()`'s
/// zero-init has a well-defined value). `closing` guards against sending a
/// Close frame twice (once we've sent one, whether app-initiated or as the
/// echo to a peer-initiated close, no further Close frame is sent).
/// Doubles as the per-connection write lock (`monitorEnter(state)`): every
/// write to `conn` — data frames, pings, and the close handshake — holds
/// this lock for the encode+write, so concurrent writers (the ping-keepalive
/// task and an application `send`/`close` call) never interleave bytes on
/// the wire.
record ConnState {
  var isOpen: Bool = false
  var closing: Bool = false
  conn: Option[Conn] = None
}

// Locked to allocate sequential registry handles atomically.
record HandleCounter {
  var next: Int = 0
}

val handleCounter: HandleCounter = HandleCounter()

val registryMap: ConcurrentDict[Int, RegistryMeta] = newConcurrentDict()

val connMap: ConcurrentDict[String, ConnState] = newConcurrentDict()

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
  val state = ConnState(isOpen = true, closing = false, conn = Some(conn))
  val key = connKey(registryHandle, connectionId)
  if not cdTryAdd(connMap, key, state) {
    return Err("connection '" + connectionId + "' already registered")
  }
  monitorEnter(meta)
  defer {
    monitorExit(meta)
  }
  meta.openCount = meta.openCount + 1
  meta.connIds.add(connectionId)
  Ok(value = state)
}

// Close a single connection's bookkeeping state under its own lock (does
// NOT touch the socket or the registry's connIds list). Returns true if the
// connection was open (caller decrements the registry open count).
func tryCloseConn(state: in ConnState): Bool {
  monitorEnter(state)
  defer {
    monitorExit(state)
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
    monitorEnter(meta)
    defer {
      monitorExit(meta)
    }
    if meta.openCount > 0 {
      meta.openCount = meta.openCount - 1
    }
  }
}

func removeConnIdFromMeta(handle: in Int, connectionId: in String): Unit {
  var meta: RegistryMeta = default()
  if cdTryGetValue(registryMap, handle, meta) {
    monitorEnter(meta)
    defer {
      monitorExit(meta)
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
  monitorEnter(meta)
  defer {
    monitorExit(meta)
  }
  val copy: List[String] = newList()
  var i = 0
  while i < meta.connIds.count {
    copy.add(meta.connIds[i])
    i = i + 1
  }
  copy
}

func invokeOnOpen(handle: in Int, connId: in String, path: in String, query: in String, remoteAddress: in String): Unit {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    return
  }
  match meta.onOpen {
    case Some(cb) -> cb(connId, path, query, remoteAddress)
    case None -> ()
  }
}

func invokeOnMessage(handle: in Int, connId: in String, msgType: in String, data: in String): Unit {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    return
  }
  match meta.onMessage {
    case Some(cb) -> cb(connId, msgType, data)
    case None -> ()
  }
}

func invokeOnClose(handle: in Int, connId: in String, code: in Int, reason: in String): Unit {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, handle, meta) {
    return
  }
  match meta.onClose {
    case Some(cb) -> cb(connId, code, reason)
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
  monitorEnter(handleCounter)
  handleCounter.next = handleCounter.next + 1
  val handle: Int = handleCounter.next
  monitorExit(handleCounter)
  val meta = RegistryMeta(maxMessageSizeBytes = maxMessageSizeBytes, pingIntervalMs = pingIntervalMs, openCount = 0)
  val _ = cdTryAdd(registryMap, handle, meta)
  Ok(handle)
}

// ─── Per-connection write path (data, ping, close) ────────────────────────────
// Every outbound frame — data, ping, and close — is written under the
// connection's own lock so concurrent writers never interleave bytes.
func writeFrameLocked(state: in ConnState, conn: in Conn, frameBytes: in slice[Byte]): Result[Unit, String] {
  monitorEnter(state)
  defer {
    monitorExit(state)
  }
  match hostWrite(conn, frameBytes) {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = TcpError.message(e))
  }
}

// Send a Close frame exactly once per connection: the first caller (whether
// the read loop echoing a peer-initiated close, or an application `close`/
// `send(..., "close", ...)` call) sends it and flips `closing`; every
// subsequent caller is a no-op. Holds the connection lock across the whole
// check-and-write so two racing closers can't both observe "not yet
// closing".
func sendCloseIfNotAlready(state: in ConnState, conn: in Conn, code: in Int, reason: in String): Unit {
  monitorEnter(state)
  defer {
    monitorExit(state)
  }
  if not state.closing {
    state.closing = true
    val _ = hostWrite(conn, encodeClose(code, reason));
    ()
  }
}

func writeMessage(state: in ConnState, conn: in Conn, messageType: in String, data: in String): Result[Unit, String] {
  if messageType == "text" {
    writeFrameLocked(state, conn, encodeText(encodeUtf8(data)))
  } else if messageType == "binary" {
    match tryDecodeBase64(data) {
      case Some(bytes) -> writeFrameLocked(state, conn, encodeBinary(bytes))
      case None -> Err("invalid base64 payload for binary frame")
    }
  } else if messageType == "ping" {
    writeFrameLocked(state, conn, encodePing(emptyBytesVal()))
  } else if messageType == "pong" {
    writeFrameLocked(state, conn, encodePong(emptyBytesVal()))
  } else if messageType == "close" {
    sendCloseIfNotAlready(state, conn, 1000, data)
    Ok(())
  } else {
    Err("unknown message type '" + messageType + "'")
  }
}

// ─── Handshake ─────────────────────────────────────────────────────────────────
// Maximum bytes accumulated while looking for the handshake's terminating
// blank line before giving up — a generous bound for real HTTP headers,
// small enough that a peer that never sends one can't grow this buffer
// without limit.
val maxHandshakeBytes: Int = 16384

func performHandshake(conn: in Conn, expectedPath: in String): Result[HandshakeResult, String] {
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
  hostClose(conn)
  if wasOpen {
    invokeOnClose(handle, connId, code, reason)
  }
}

// ─── Ping keepalive ─────────────────────────────────────────────────────────────
func runPingLoop(state: in ConnState, conn: in Conn, pingIntervalMs: in Int): Unit {
  var running = true
  while running {
    threadSleep(pingIntervalMs)
    // `state` is the SAME shared object `registerConnection` stored in
    // `connMap` (records are reference types), so reading `isOpen`/
    // `closing` here observes the read loop's teardown directly — no
    // separate dict lookup needed.
    if not state.isOpen or state.closing {
      running = false
    } else {
      match writeFrameLocked(state, conn, encodePing(emptyBytesVal())) {
        case Ok(_) -> ()
        case Err(_) -> {
          running = false
        }
      }
    }
  }
}

// ─── Connection lifecycle ───────────────────────────────────────────────────────
func handleConnection(
  handle: in Int,
  conn: in Conn,
  expectedPath: in String,
  maxMessageSizeBytes: in Int,
  pingIntervalMs: in Int,
): Unit {
  match performHandshake(conn, expectedPath) {
    case Err(_) -> hostClose(conn)
    case Ok(hsResult) -> {
      val connId = uuidToString(newUuid())
      match registerConnection(handle, connId, conn) {
        case Err(_) -> hostClose(conn)
        case Ok(state) -> {
          val remoteAddress = hostRemoteAddress(conn)
          invokeOnOpen(handle, connId, hsResult.request.path, hsResult.request.query, remoteAddress)
          if pingIntervalMs > 0 {
            val _ = taskRun({ -> runPingLoop(state, conn, pingIntervalMs) })
          }
          val outcome = runReadLoop(handle, connId, state, conn, maxMessageSizeBytes, hsResult.leftover)
          finishConnection(handle, connId, state, conn, outcome.code, outcome.reason)
        }
      }
    }
  }
}

func wsAcceptLoop(
  handle: in Int,
  transport: in Listener,
  path: in String,
  maxMessageSizeBytes: in Int,
  pingIntervalMs: in Int,
): Unit {
  var running = true
  while running {
    match hostAccept(transport) {
      case Ok(conn) -> {
        val _ = taskRun({ -> handleConnection(handle, conn, path, maxMessageSizeBytes, pingIntervalMs) })
      }
      case Err(e) -> match e { case AcceptFailed(_) -> { running = false }; case BindFailed(_) -> { running = false }; case _ -> () }
    }
  }
}

// ─── Public kernel surface ──────────────────────────────────────────────────────
/// Start a real WebSocket server: binds `host:port`, upgrades exactly `path`
/// to WebSocket (RFC 6455), and invokes the given callbacks for the
/// connection lifecycle. See the module header for the concurrency model and
/// the `pingIntervalMs` note.
@stable(since = "0.1")
pub func startServer(
  host: in String,
  port: in Int,
  path: in String,
  maxMessageSizeBytes: in Int,
  onOpen: in (String, String, String, String) -> Unit,
  onMessage: in (String, String, String) -> Unit,
  onClose: in (String, Int, String) -> Unit,
  onError: in (String, String) -> Unit,
): Result[Int, String]
  requires: host.length > 0
  requires: port > 0
  requires: path.length > 0
  requires: maxMessageSizeBytes >= 1024
{
  val pingIntervalMs = resolvePingIntervalMs()
  match hostListen(resolveBindHost(host), port) {
    case Err(e) -> Err(error = TcpError.message(e))
    case Ok(transport) -> {
      monitorEnter(handleCounter)
      handleCounter.next = handleCounter.next + 1
      val handle: Int = handleCounter.next
      monitorExit(handleCounter)
      val meta = RegistryMeta(
        maxMessageSizeBytes = maxMessageSizeBytes,
        pingIntervalMs = pingIntervalMs,
        openCount = 0,
        onOpen = Some(onOpen),
        onMessage = Some(onMessage),
        onClose = Some(onClose),
        onError = Some(onError),
        listener = Some(transport)
      )
      if not cdTryAdd(registryMap, handle, meta) {
        hostStopListener(transport)
        return Err(error = "registry handle collision (unreachable)")
      }
      val _ = taskRun({ -> wsAcceptLoop(handle, transport, path, maxMessageSizeBytes, pingIntervalMs) })
      Ok(value = handle)
    }
  }
}

/// Stop a server started by `startServer`. In-flight connections finish
/// their current frame; the accept loop ends once the stopped listener's
/// next accept fails.
@stable(since = "0.1")
pub func stopServer(registryHandle: in Int): Result[Unit, String] {
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, registryHandle, meta) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  match meta.listener {
    case Some(transport) -> {
      hostStopListener(transport)
      Ok(())
    }
    case None -> Err("registry " + registryHandle.toString() + " has no running server")
  }
}

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
  var i = 0
  while i < ids.count {
    match send(registryHandle, ids[i], messageType, data) {
      case Ok(_) -> ()
      case Err(e) -> {
        if not hasErr {
          hasErr = true
          firstErr = e
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

// ─── Rate limiter (tumbling window) ──────────────────────────────────────────
//
// Uses a tumbling (fixed-reset) 60-second window per key, NOT the sliding
// window that the deleted F# WsHost.fs used (which maintained per-message
// timestamps and filtered to the trailing 60s).  The tumbling window allows
// up to 2× the nominal rate at window boundaries; the production rate limiter
// (#778) should implement the sliding window if boundary bursting is a concern.
// The burst budget is one-shot: it does not refill when the window resets.
record RateEntry {
  var windowStartMs: Long = 0i64
  var usedInWindow: Int = 0
  var burstAvailable: Int = 0
}

// Single global lock serialises all rate-limiter mutations.
record RateLock {
}

val rateLock: RateLock = RateLock()

val rateLimitMap: ConcurrentDict[String, RateEntry] = newConcurrentDict()

@stable(since = "0.1")
pub func checkRateLimit(key: in String, messagesPerMinute: in Int, burstSize: in Int): Bool
  requires: key.length > 0
  requires: messagesPerMinute > 0
  requires: burstSize > 0
{
  val nowMs = nowEpochMillis()
  monitorEnter(rateLock)
  defer {
    monitorExit(rateLock)
  }

  var re: RateEntry = default()
  if not cdTryGetValue(rateLimitMap, key, re) {
    val newEntry = RateEntry(windowStartMs = nowMs, usedInWindow = 0, burstAvailable = burstSize)
    val _ = cdTryAdd(rateLimitMap, key, newEntry)
    var re2: RateEntry = default()
    if cdTryGetValue(rateLimitMap, key, re2) {
      re = re2
    } else {
      re = newEntry
    }
  }

  val elapsed: Long = nowMs - re.windowStartMs
  if elapsed >= 60000i64 {
    re.windowStartMs = nowMs
    re.usedInWindow = 0
  }

  if re.usedInWindow < messagesPerMinute {
    re.usedInWindow = re.usedInWindow + 1
    return true
  }

  if re.burstAvailable > 0 {
    re.burstAvailable = re.burstAvailable - 1
    re.usedInWindow = re.usedInWindow + 1
    return true
  }

  false
}
