//! Ws.Kernel.Jvm — Undertow WebSockets extern boundary.
//!
//! Bridges the Ws package to a real Undertow WebSocket server
//! (io.undertow:undertow-core, see lyric-ws/lyric.toml's `[maven]` table):
//!   startServer()        — starts a real Undertow server, upgrades the given
//!                          path to WebSocket, and wires the connection
//!                          lifecycle (onOpen/onMessage/onClose/onError)
//!                          through to the caller's callbacks
//!   stopServer()         — stops a server started by startServer()
//!   createRegistry()     — allocates a bookkeeping-only registry (no live
//!                          server); kept for API parity with Ws.Kernel.Net
//!                          and for tests that only exercise error paths
//!   send()               — send a typed frame to one connection
//!   broadcast()          — send a typed frame to all connections
//!   close()              — close a connection with an RFC 6455 numeric code
//!   connectionCount()    — number of open connections
//!   isConnected()        — query whether a specific connection is open
//!   checkRateLimit()     — sliding-window rate limiter keyed by arbitrary string
//!
//! Every extern binding here is `extern type` + auto-FFI (metadata-resolved
//! at compile time) against real `io.undertow.*` / `org.xnio.*` / JDK
//! classes — no `extern package` (a confirmed no-op FFI mechanism) and no
//! hand-routed host shim.  `WebSocketConnectionCallback` and the
//! receive/close listeners (`org.xnio.ChannelListener`) are real Lyric
//! records implementing the real JDK interfaces via `impl <ExternInterface>
//! for Record` — the JVM analog of docs/51, whose interface-name and
//! param/return-type resolution this library's development uncovered and
//! fixed in `lyric-compiler/jvm/codegen/06_items.l` (`constraintRefToJvmClass`,
//! `holderAwareParamTypes`, `lowerImplMethod`; see
//! `ffi_iface_impl_jvm_self_test.l`).
//!
//! Known, documented gap: fragmented (multi-frame, `fin=false`) WebSocket
//! messages are not reassembled.  Each `WebSocketFrameType.CONTINUATION`
//! frame is drained (so the channel does not stall) but not dispatched to
//! `onMessage` — only single-frame TEXT/BINARY/PING/PONG messages (the
//! common case: most WebSocket clients, including the JDK's own
//! `io.undertow.websockets.client.WebSocketClient` used by this library's
//! own end-to-end test, send single-frame messages by default) are
//! delivered.  Automatic ping-interval keepalives are not wired either
//! (the `pingIntervalMs` parameter threads through for API symmetry with
//! `createRegistry` but nothing currently schedules pings).  Both are
//! real, scoped gaps — not silent stubs — and are candidates for a
//! tracked follow-up rather than being pretended-away here.
//!
//! Text/binary payload conversion (bytes <-> String) is done via direct
//! JDK calls (`java.lang.String(byte[], String)`, `java.util.Base64`)
//! rather than `Std.Encoding`: `Std.Encoding.tryDecodeUtf8` (and every
//! other pure-Lyric byte-indexing helper in that module) reads a
//! `slice[Byte]` element and calls a numeric builtin (`.toInt()`) on it,
//! which on the self-hosted JVM backend resolves against the slice's
//! JVM-erased `Object` element type instead of the Lyric-level `Byte`
//! static type, failing to compile (`no matching instance or inherited
//! method for 'java.lang.Object.toInt()'`) — a genuine, pre-existing
//! self-hosted JVM backend gap, confirmed in complete isolation from this
//! library, that is out of this library's scope to fix.  `String(byte[])`
//! decoding is therefore lenient (invalid UTF-8 substitutes U+FFFD per the
//! JDK's default `CodingErrorAction`) rather than the stricter validate-
//! and-reject behaviour `Std.Encoding.tryDecodeUtf8` gives on `.NET` — a
//! second, narrower, documented deviation from `Ws.Kernel.Net`.
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "jvm")
package Ws.Kernel.Jvm

import Std.Core

// ─── JDK / Undertow / XNIO externs ────────────────────────────────────────────
extern type JUndertow = "io.undertow.Undertow"

extern type JUndertowBuilder = "io.undertow.Undertow$Builder"

extern type JHandlers = "io.undertow.Handlers"

extern type JPathHandler = "io.undertow.server.handlers.PathHandler"

extern type JWsConnectionCallback = "io.undertow.websockets.WebSocketConnectionCallback"

extern type JWsHandshakeHandler = "io.undertow.websockets.WebSocketProtocolHandshakeHandler"

extern type JWsHttpExchange = "io.undertow.websockets.spi.WebSocketHttpExchange"

extern type JWsChannel = "io.undertow.websockets.core.WebSocketChannel"

extern type JWsStreamSourceFrameChannel = "io.undertow.websockets.core.StreamSourceFrameChannel"

extern type JChannelListener = "org.xnio.ChannelListener"

extern type JChannelListenerSetter = "org.xnio.ChannelListener$Setter"

extern type JWebSockets = "io.undertow.websockets.core.WebSockets"

extern type JInetSocketAddress = "java.net.InetSocketAddress"

extern type JByteBuffer = "java.nio.ByteBuffer"

extern type JChannels = "java.nio.channels.Channels"

extern type JInputStream = "java.io.InputStream"

extern type JStr = "java.lang.String"

extern type JBase64 = "java.util.Base64"

extern type JBase64Encoder = "java.util.Base64$Encoder"

extern type JBase64Decoder = "java.util.Base64$Decoder"

extern type JObjects = "java.util.Objects"

extern type JUUID = "java.util.UUID"

extern type JConcurrentHashMap = "java.util.concurrent.ConcurrentHashMap"

extern type JAtomicInteger = "java.util.concurrent.atomic.AtomicInteger"

extern type JReentrantLock = "java.util.concurrent.locks.ReentrantLock"

extern type JCollection = "java.util.Collection"

extern type JIterator = "java.util.Iterator"

extern type JSystem = "java.lang.System"

// ─── Registry state ───────────────────────────────────────────────────────────
// `onOpen`/`onMessage`/`onClose`/`onError` are `None` for a bookkeeping-only
// registry allocated via `createRegistry` (no live server, kept for parity
// with `Ws.Kernel.Net` and error-path tests); `startServer` fills them in.
record RegistryState {
  handle: Int
  maxMessageSizeBytes: Int
  var openCount: Int
  connMap: JConcurrentHashMap
  onOpen: Option[(String, String, String, String) -> Unit]
  onMessage: Option[(String, String, String) -> Unit]
  onClose: Option[(String, Int, String) -> Unit]
  onError: Option[(String, String) -> Unit]
  var server: Option[JUndertow]
  lock: JReentrantLock
}

val registryMap: JConcurrentHashMap = JConcurrentHashMap.new()

val handleCounter: JAtomicInteger = JAtomicInteger.new(0)

func nextHandle(): Int {
  handleCounter.incrementAndGet()
}

func lookupRegistry(handle: in Int): RegistryState {
  val state: RegistryState = registryMap.get(handle.toString())
  state
}

func incrementOpenCount(state: in RegistryState): Unit {
  state.lock.lock()
  defer {
    state.lock.unlock()
  }
  state.openCount = state.openCount + 1
}

func decrementOpenCount(state: in RegistryState): Unit {
  state.lock.lock()
  defer {
    state.lock.unlock()
  }
  if state.openCount > 0 {
    state.openCount = state.openCount - 1
  }
}

func removeConnection(handle: in Int, connId: in String): Unit {
  val state = lookupRegistry(handle)
  if JObjects.isNull(state) {
    return
  }
  val existed: JWsChannel = state.connMap.remove(connId)
  if not JObjects.isNull(existed) {
    decrementOpenCount(state)
  }
}

func invokeOnOpen(handle: in Int, connId: in String, path: in String, query: in String, remoteAddress: in String): Unit {
  val state = lookupRegistry(handle)
  if JObjects.isNull(state) {
    return
  }
  match state.onOpen {
    case Some(cb) -> cb(connId, path, query, remoteAddress)
    case None -> ()
  }
}

func invokeOnMessage(handle: in Int, connId: in String, msgType: in String, data: in String): Unit {
  val state = lookupRegistry(handle)
  if JObjects.isNull(state) {
    return
  }
  match state.onMessage {
    case Some(cb) -> cb(connId, msgType, data)
    case None -> ()
  }
}

func invokeOnClose(handle: in Int, connId: in String, code: in Int, reason: in String): Unit {
  val state = lookupRegistry(handle)
  if JObjects.isNull(state) {
    return
  }
  match state.onClose {
    case Some(cb) -> cb(connId, code, reason)
    case None -> ()
  }
}

func invokeOnError(handle: in Int, connId: in String, message: in String): Unit {
  val state = lookupRegistry(handle)
  if JObjects.isNull(state) {
    return
  }
  match state.onError {
    case Some(cb) -> cb(connId, message)
    case None -> ()
  }
}

// ─── Frame send helpers ───────────────────────────────────────────────────────
func sendTextFrame(channel: in JWsChannel, text: in String): Result[Unit, String] {
  try {
    JWebSockets.sendTextBlocking(text, channel)
    Ok(())
  } catch Exception as e {
    Err(e.message)
  }
}

func sendBinaryFrame(channel: in JWsChannel, bytes: in slice[Byte]): Result[Unit, String] {
  try {
    val buf: JByteBuffer = JByteBuffer.wrap(bytes)
    JWebSockets.sendBinaryBlocking(buf, channel)
    Ok(())
  } catch Exception as e {
    Err(e.message)
  }
}

func sendPingFrame(channel: in JWsChannel): Result[Unit, String] {
  try {
    val buf: JByteBuffer = JByteBuffer.allocate(0)
    JWebSockets.sendPingBlocking(buf, channel)
    Ok(())
  } catch Exception as e {
    Err(e.message)
  }
}

func sendPongFrame(channel: in JWsChannel): Result[Unit, String] {
  try {
    val buf: JByteBuffer = JByteBuffer.allocate(0)
    JWebSockets.sendPongBlocking(buf, channel)
    Ok(())
  } catch Exception as e {
    Err(e.message)
  }
}

// The generic `send`/`broadcast` surface carries only a reason string (no
// separate close-code parameter, per `Ws.messageDataString`'s `Close(code,
// reason) -> reason` projection in ws.l) — sent with the RFC 6455 Normal
// (1000) code.  Callers that need an explicit code use the dedicated
// `close()` kernel function below.
func sendCloseFrameDefault(channel: in JWsChannel, reason: in String): Result[Unit, String] {
  sendCloseFrame(channel, 1000, reason)
}

func sendCloseFrame(channel: in JWsChannel, code: in Int, reason: in String): Result[Unit, String] {
  try {
    JWebSockets.sendCloseBlocking(code, reason, channel)
    Ok(())
  } catch Exception as e {
    Err(e.message)
  }
}

// Decode a Base64 payload string to bytes via `java.util.Base64.getDecoder()`
// (throws `IllegalArgumentException` on malformed input, caught below) —
// deliberately not `Std.Encoding.tryDecodeBase64` (see file header).
func base64ToBytes(s: in String): Result[slice[Byte], String] {
  try {
    val dec: JBase64Decoder = JBase64.getDecoder()
    Ok(dec.decode(s))
  } catch Exception as e {
    Err(e.message)
  }
}

func sendFrame(channel: in JWsChannel, messageType: in String, data: in String): Result[Unit, String] {
  if messageType == "text" {
    sendTextFrame(channel, data)
  } else if messageType == "binary" {
    match base64ToBytes(data) {
      case Ok(bytes) -> sendBinaryFrame(channel, bytes)
      case Err(_) -> Err("invalid base64 payload for binary frame")
    }
  } else if messageType == "ping" {
    sendPingFrame(channel)
  } else if messageType == "pong" {
    sendPongFrame(channel)
  } else if messageType == "close" {
    sendCloseFrameDefault(channel, data)
  } else {
    Err("unknown message type '" + messageType + "'")
  }
}

// ─── Frame receive dispatch ───────────────────────────────────────────────────
// Reads one complete frame's payload via `Channels.newInputStream` +
// `InputStream.readAllBytes()` (no manual `ByteBuffer` position bookkeeping —
// `readAllBytes()` blocks to EOF and returns an exactly-sized array).
func readFramePayload(frame: in JWsStreamSourceFrameChannel): slice[Byte] {
  val input: JInputStream = JChannels.newInputStream(frame)
  input.readAllBytes()
}

// Lenient UTF-8 decode via `java.lang.String(byte[], String)` — see file
// header for why this doesn't use `Std.Encoding.tryDecodeUtf8`.
func bytesToUtf8Lenient(bytes: in slice[Byte]): String {
  JStr.new(bytes, "UTF-8")
}

func bytesToBase64(bytes: in slice[Byte]): String {
  val enc: JBase64Encoder = JBase64.getEncoder()
  enc.encodeToString(bytes)
}

func dispatchFrame(handle: in Int, connId: in String, frame: in JWsStreamSourceFrameChannel): Unit {
  val frameType = frame.getType().toString()
  val bytes = readFramePayload(frame)
  if frameType == "TEXT" {
    invokeOnMessage(handle, connId, "text", bytesToUtf8Lenient(bytes))
  } else if frameType == "BINARY" {
    invokeOnMessage(handle, connId, "binary", bytesToBase64(bytes))
  } else if frameType == "PING" {
    invokeOnMessage(handle, connId, "ping", "")
  } else if frameType == "PONG" {
    invokeOnMessage(handle, connId, "pong", "")
  } else {
    // CLOSE is handled by the close listener; CONTINUATION (fragmented
    // messages) and UNKOWN are a documented gap (see file header) — the
    // bytes above are already drained so the channel does not stall.
    ()
  }
}

func pumpFrames(handle: in Int, connId: in String, channel: in JWsChannel): Unit {
  var more = true
  while more {
    val frame: JWsStreamSourceFrameChannel = channel.receive()
    if JObjects.isNull(frame) {
      more = false
    } else {
      dispatchFrame(handle, connId, frame)
      frame.close()
    }
  }
}

// ─── Connection lifecycle listeners ───────────────────────────────────────────
record WsReceiveListener {
  registryHandle: Int
  connId: String
}

impl JChannelListener for WsReceiveListener {
  func handleEvent(channel: in JWsChannel): Unit {
    try {
      pumpFrames(self.registryHandle, self.connId, channel)
    } catch Exception as e {
      invokeOnError(self.registryHandle, self.connId, e.message)
    }
  }
}

record WsCloseListener {
  registryHandle: Int
  connId: String
}

impl JChannelListener for WsCloseListener {
  func handleEvent(channel: in JWsChannel): Unit {
    val code = channel.getCloseCode()
    val reasonRaw = channel.getCloseReason()
    val reason = reasonRaw ?? ""
    removeConnection(self.registryHandle, self.connId)
    invokeOnClose(self.registryHandle, self.connId, code, reason)
  }
}

record WsConnectCallback {
  registryHandle: Int
}

impl JWsConnectionCallback for WsConnectCallback {
  func onConnect(exchange: in JWsHttpExchange, channel: in JWsChannel): Unit {
    val connId: String = JUUID.randomUUID().toString()
    val state = lookupRegistry(self.registryHandle)
    if JObjects.isNull(state) {
      return
    }
    state.connMap.put(connId, channel)
    incrementOpenCount(state)

    val recvListener = WsReceiveListener(registryHandle = self.registryHandle, connId = connId)
    val closeListener = WsCloseListener(registryHandle = self.registryHandle, connId = connId)
    val recvSetter: JChannelListenerSetter = channel.getReceiveSetter()
    recvSetter.set(recvListener)
    val closeSetter: JChannelListenerSetter = channel.getCloseSetter()
    closeSetter.set(closeListener)
    channel.resumeReceives()

    val reqPathRaw = exchange.getRequestURI()
    val reqPath = reqPathRaw ?? ""
    val reqQueryRaw = exchange.getQueryString()
    val reqQuery = reqQueryRaw ?? ""
    val srcAddr: JInetSocketAddress = channel.getSourceAddress()
    val remoteAddress = if JObjects.isNull(srcAddr) { "" } else { srcAddr.toString() }
    invokeOnOpen(self.registryHandle, connId, reqPath, reqQuery, remoteAddress)
  }
}

// ─── Public kernel surface ─────────────────────────────────────────────────────
/// Allocate a bookkeeping-only connection registry (no live server).  Kept
/// for parity with `Ws.Kernel.Net` and for tests that only exercise the
/// "unknown registry/connection" error paths.  Use `startServer` to get a
/// registry backed by a real, running Undertow WebSocket server.
@stable(since = "0.1")
pub func createRegistry(maxMessageSizeBytes: in Int, pingIntervalMs: in Int): Result[Int, String]
  requires: maxMessageSizeBytes >= 1024
  requires: pingIntervalMs >= 0
{
  val handle = nextHandle()
  val state = RegistryState(
    handle = handle,
    maxMessageSizeBytes = maxMessageSizeBytes,
    openCount = 0,
    connMap = JConcurrentHashMap.new(),
    onOpen = None,
    onMessage = None,
    onClose = None,
    onError = None,
    server = None,
    lock = JReentrantLock.new()
  )
  registryMap.put(handle.toString(), state)
  Ok(handle)
}

/// Start a real Undertow WebSocket server: binds `host:port`, upgrades
/// exactly `path` to WebSocket, and invokes the given callbacks for the
/// connection lifecycle.  Returns a registry handle usable with
/// `send`/`broadcast`/`close`/`connectionCount`/`isConnected`.
///
/// Callback signatures (kept primitive, matching this kernel's other
/// functions, so `Ws.Kernel.Jvm` never needs to import the public `Ws`
/// package's `WsHandler`/`WsContext`/`WsMessage` types — `ws.l` does the
/// primitive <-> rich-type translation, avoiding an import cycle):
///   onOpen(connectionId, path, query, remoteAddress)
///   onMessage(connectionId, messageType, data)      — messageType per `send`
///   onClose(connectionId, code, reason)
///   onError(connectionId, message)
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
  val handle = nextHandle()
  val state = RegistryState(
    handle = handle,
    maxMessageSizeBytes = maxMessageSizeBytes,
    openCount = 0,
    connMap = JConcurrentHashMap.new(),
    onOpen = Some(onOpen),
    onMessage = Some(onMessage),
    onClose = Some(onClose),
    onError = Some(onError),
    server = None,
    lock = JReentrantLock.new()
  )
  registryMap.put(handle.toString(), state)

  try {
    val callback = WsConnectCallback(registryHandle = handle)
    val handshakeHandler: JWsHandshakeHandler = JWsHandshakeHandler.new(callback)
    val pathHandler: JPathHandler = JHandlers.path()
    val routedHandler: JPathHandler = pathHandler.addExactPath(path, handshakeHandler)
    var builder: JUndertowBuilder = JUndertow.builder()
    builder = builder.addHttpListener(port, host)
    builder = builder.setHandler(routedHandler)
    val server: JUndertow = builder.build()
    server.start()
    state.server = Some(server)
    Ok(handle)
  } catch Exception as e {
    registryMap.remove(handle.toString())
    Err(e.message)
  }
}

/// Stop a server started by `startServer`.
@stable(since = "0.1")
pub func stopServer(registryHandle: in Int): Result[Unit, String] {
  val state = lookupRegistry(registryHandle)
  if JObjects.isNull(state) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  match state.server {
    case Some(srv) -> {
      // Explicit re-annotation: the `Some(srv)` binding from a
      // `Option[JUndertow]` field degrades to `Object` without it, and
      // `.stop()` then fails to resolve (auto-FFI has no `Object.stop()`).
      val realSrv: JUndertow = srv
      realSrv.stop()
      Ok(())
    }
    case None -> Err("registry " + registryHandle.toString() + " has no running server")
  }
}

/// Send a WebSocket frame to a single connection.
/// `messageType` is one of: "text", "binary", "ping", "pong", "close".
/// `data` is the frame payload (UTF-8 string for text, Base64 for binary,
/// empty for ping/pong, the reason phrase for close).
@stable(since = "0.1")
pub func send(
  registryHandle: in Int, connectionId: in String, messageType: in String, data: in String
): Result[Unit, String]
  requires: connectionId.length > 0
  requires: messageType.length > 0
{
  val state = lookupRegistry(registryHandle)
  if JObjects.isNull(state) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  val channel: JWsChannel = state.connMap.get(connectionId)
  if JObjects.isNull(channel) {
    return Err("unknown connection '" + connectionId + "'")
  }
  sendFrame(channel, messageType, data)
}

/// Broadcast a WebSocket frame to all currently open connections.
/// Returns the first error encountered, if any, after attempting delivery
/// to every connection.
@stable(since = "0.1")
pub func broadcast(registryHandle: in Int, messageType: in String, data: in String): Result[Unit, String]
  requires: messageType.length > 0
{
  val state = lookupRegistry(registryHandle)
  if JObjects.isNull(state) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  val values: JCollection = state.connMap.values()
  val it: JIterator = values.iterator()
  var hasErr = false
  var firstErr = ""
  while it.hasNext() {
    val channel: JWsChannel = it.next()
    match sendFrame(channel, messageType, data) {
      case Ok(_) -> ()
      case Err(e) -> {
        if not hasErr {
          hasErr = true
          firstErr = e
        }
      }
    }
  }
  if hasErr {
    Err(firstErr)
  } else {
    Ok(())
  }
}

/// Close a connection with an RFC 6455 numeric close code and reason.
/// Closing an unknown registry or connection is a no-op (matches
/// `Ws.Kernel.Net`'s bookkeeping behaviour).
@stable(since = "0.1")
pub func close(registryHandle: in Int, connectionId: in String, code: in Int, reason: in String): Result[Unit, String]
  requires: connectionId.length > 0
{
  val state = lookupRegistry(registryHandle)
  if JObjects.isNull(state) {
    return Ok(())
  }
  val channel: JWsChannel = state.connMap.get(connectionId)
  if JObjects.isNull(channel) {
    return Ok(())
  }
  sendCloseFrame(channel, code, reason)
}

/// Return the number of currently open connections in this registry.
@stable(since = "0.1")
pub func connectionCount(registryHandle: in Int): Int {
  val state = lookupRegistry(registryHandle)
  if JObjects.isNull(state) {
    0
  } else {
    state.openCount
  }
}

/// Return whether the given connection is currently open.
@stable(since = "0.1")
pub func isConnected(registryHandle: in Int, connectionId: in String): Bool
  requires: connectionId.length > 0
{
  val state = lookupRegistry(registryHandle)
  if JObjects.isNull(state) {
    return false
  }
  val channel: JWsChannel = state.connMap.get(connectionId)
  if JObjects.isNull(channel) {
    false
  } else {
    channel.isOpen()
  }
}

// ─── Rate limiting ────────────────────────────────────────────────────────────
// Tumbling (fixed-reset) 60-second window per key, matching `Ws.Kernel.Net`'s
// documented semantics (not the deleted F# WsHost.fs's sliding window).  The
// burst budget is one-shot: it does not refill when the window resets.
record RateEntry {
  var windowStartMs: Long
  var usedInWindow: Int
  var burstAvailable: Int
  lock: JReentrantLock
}

val rateLimitMap: JConcurrentHashMap = JConcurrentHashMap.new()

func nowMs(): Long {
  JSystem.currentTimeMillis()
}

/// Check whether a call identified by `key` is within the rate limit.
/// Returns true (allow) or false (deny).
/// State is per-process and per-key; resets on process restart.
@stable(since = "0.1")
pub func checkRateLimit(key: in String, messagesPerMinute: in Int, burstSize: in Int): Bool
  requires: key.length > 0
  requires: messagesPerMinute > 0
  requires: burstSize > 0
{
  val fresh = RateEntry(
    windowStartMs = nowMs(),
    usedInWindow = 0,
    burstAvailable = burstSize,
    lock = JReentrantLock.new()
  )
  // No explicit type annotation on `prior` — matches `Lyric.Resilience`'s
  // proven-working `circuitRegistry.putIfAbsent` idiom.  Pre-annotating the
  // intermediate binding's type strips the nullable-return marker the type
  // checker attaches to the raw `putIfAbsent` call, so `??` below then
  // rejects it as "LHS must be a nullable type".
  val prior = rateLimitMap.putIfAbsent(key, fresh)
  val entry: RateEntry = prior ?? fresh

  entry.lock.lock()
  defer {
    entry.lock.unlock()
  }

  val elapsed: Long = nowMs() - entry.windowStartMs
  if elapsed >= 60000i64 {
    entry.windowStartMs = nowMs()
    entry.usedInWindow = 0
  }

  if entry.usedInWindow < messagesPerMinute {
    entry.usedInWindow = entry.usedInWindow + 1
    return true
  }

  if entry.burstAvailable > 0 {
    entry.burstAvailable = entry.burstAvailable - 1
    entry.usedInWindow = entry.usedInWindow + 1
    return true
  }

  false
}
