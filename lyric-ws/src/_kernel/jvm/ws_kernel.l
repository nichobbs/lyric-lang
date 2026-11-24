//! Ws.Kernel.Jvm — the Undertow WebSocket endpoint behind `Web.addWebSocket`
//! on the JVM, and nothing else.
//!
//! `Ws.startServer` on the JVM is the pure-Lyric RFC 6455 server over
//! `Std.TcpHost` (`Ws.Kernel.Net`, docs/73 slice S7a), the same code as dotnet
//! and native. What remains here exists only because `lyric-web` on the JVM
//! still serves HTTP through Undertow (`Web.addWebSocket` mounts
//! `endpointHandler` on its `PathHandler`) until `Web.serve` moves to the
//! shared pure-Lyric server (docs/73 S4 and S6); `Web.addWebSocket` then
//! moves to `Ws.Kernel.Net.adoptConnection` (S7b) and this package, with the
//! `[maven]` Undertow coordinates in `lyric-ws/lyric.toml`, is deleted.
//!
//!   createEndpoint()     — allocates an endpoint registry (no listener)
//!   endpointHandler()    — the Undertow handler that upgrades a request to
//!                          that endpoint, behind the Origin check (#7243)
//!   stopServer()         — always `Err`: an endpoint has no listener of its own
//!   send()/broadcast()/close()/connectionCount()/isConnected()
//!                        — operate on an endpoint's connections
//!   ownsHandle()         — whether a registry handle belongs to this kernel
//!
//! Registry handles from this kernel start at `handleBase`, far above the
//! small sequential handles `Ws.Kernel.Net` allocates, so `Ws` can route a
//! `NativeRegistry` to the kernel that owns it by handle alone.
//!
//! Known, documented gap (inherited, and the reason `Ws.startServer` left this
//! kernel): fragmented (multi-frame, `fin=false`) messages are not reassembled
//! and no ping keepalive is sent. Both exist in `Ws.Kernel.Net`, which
//! `Web.addWebSocket` gets in S7b.
//!
//! Every extern binding here is `extern type` + auto-FFI against real
//! `io.undertow.*` / `org.xnio.*` / JDK classes. `WebSocketConnectionCallback`
//! and the receive/close listeners (`org.xnio.ChannelListener`) are Lyric
//! records implementing the real interfaces via `impl <ExternInterface> for
//! Record` (docs/51).
//!
//! Text/binary payload conversion uses direct JDK calls
//! (`java.lang.String(byte[], String)`, `java.util.Base64`); decoding is
//! lenient (invalid UTF-8 becomes U+FFFD), unlike `Ws.Kernel.Net`.
//!
//! Only active when compiled with feature = "jvm".
@cfg(feature = "jvm")
@io
package Ws.Kernel.Jvm

import Std.Core
import Std.Console
import Std.Collections
import Ws.Frame
import Ws.Handshake

// ─── JDK / Undertow / XNIO externs ────────────────────────────────────────────
extern type JWsConnectionCallback = "io.undertow.websockets.WebSocketConnectionCallback"

extern type JWsHandshakeHandler = "io.undertow.websockets.WebSocketProtocolHandshakeHandler"

extern type JWsHttpExchange = "io.undertow.websockets.spi.WebSocketHttpExchange"

extern type JWsChannel = "io.undertow.websockets.core.WebSocketChannel"

extern type JWsStreamSourceFrameChannel = "io.undertow.websockets.core.StreamSourceFrameChannel"

extern type JChannelListener = "org.xnio.ChannelListener"

extern type JNioChannel = "java.nio.channels.Channel"

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

// Origin check ahead of the upgrade (#7243): a Lyric `HttpHandler` wraps the
// handshake handler, so a refused handshake is answered 403 before Undertow
// writes its `101 Switching Protocols`.
extern type JHttpHandler = "io.undertow.server.HttpHandler"

extern type JHttpServerExchange = "io.undertow.server.HttpServerExchange"

extern type JHeaderMap = "io.undertow.util.HeaderMap"

extern type JJavaMap = "java.util.Map"

extern type JJavaList = "java.util.List"

extern type JJavaSet = "java.util.Set"

// ─── Registry state ───────────────────────────────────────────────────────────
ref record RegistryState {
  handle: Int
  maxMessageSizeBytes: Int
  var openCount: Int
  connMap: JConcurrentHashMap
  onOpen: Option[(String, String, String, String, Map[String, String]) -> Unit]
  onMessage: Option[(String, String, String) -> Unit]
  onClose: Option[(String, Int, String) -> Unit]
  onError: Option[(String, String) -> Unit]
  lock: JReentrantLock
}

val registryMap: JConcurrentHashMap = JConcurrentHashMap.new()

// Handles of this kernel start here; `Ws.Kernel.Net`'s are small and sequential.
val handleBase: Int = 1000000000

val handleCounter: JAtomicInteger = JAtomicInteger.new(handleBase)

/// Whether `handle` was allocated by this kernel (an endpoint), as opposed to
/// `Ws.Kernel.Net` (a `startServer` or bookkeeping registry).
pub func ownsHandle(handle: in Int): Bool {
  handle >= handleBase
}

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

func invokeOnOpen(
  handle: in Int,
  connId: in String,
  path: in String,
  query: in String,
  remoteAddress: in String,
  headers: in Map[String, String],
): Unit {
  val state = lookupRegistry(handle)
  if JObjects.isNull(state) {
    return
  }
  match state.onOpen {
    case Some(cb) -> {
      try {
        cb(connId, path, query, remoteAddress, headers);
        ()
      } catch Exception as e {
        reportHandlerFailure(handle, connId, "onOpen", e.message);
        ()
      }
    }
    case None -> ()
  }
}

func invokeOnMessage(handle: in Int, connId: in String, msgType: in String, data: in String): Unit {
  val state = lookupRegistry(handle)
  if JObjects.isNull(state) {
    return
  }
  match state.onMessage {
    case Some(cb) -> {
      try {
        cb(connId, msgType, data);
        ()
      } catch Exception as e {
        reportHandlerFailure(handle, connId, "onMessage", e.message);
        ()
      }
    }
    case None -> ()
  }
}

func invokeOnClose(handle: in Int, connId: in String, code: in Int, reason: in String): Unit {
  val state = lookupRegistry(handle)
  if JObjects.isNull(state) {
    return
  }
  match state.onClose {
    case Some(cb) -> {
      try {
        cb(connId, code, reason);
        ()
      } catch Exception as e {
        reportHandlerFailure(handle, connId, "onClose", e.message);
        ()
      }
    }
    case None -> ()
  }
}

// A handler callback that throws must not end the connection's read loop
// unobserved: the failure is reported through `onError` and the connection
// carries on.  An `onError` that throws as well is written to stderr, the
// only place left to report it.
func reportHandlerFailure(handle: in Int, connId: in String, stage: in String, message: in String): Unit {
  val text = "the " + stage + " handler failed: " + message
  try {
    invokeOnError(handle, connId, text);
    ()
  } catch Exception as e {
    Console.error("lyric-ws: connection " + connId + ": " + text + "; the onError handler also failed: " + e.message);
    ()
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
  if not isSendableCloseCode(code) {
    return Err("close code " + code.toString() + " may not be sent (RFC 6455 7.4.1)")
  }
  try {
    JWebSockets.sendCloseBlocking(code, fitCloseReason(reason), channel)
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

// Undertow's low-level `receive()` API leaves the reply to a peer's close
// frame to the application (only `AbstractReceiveListener` sends it), and an
// unanswered close leaves the peer waiting until it times out (RFC 6455
// 5.5.1).  Echo the peer's status code, or an empty close when it sent none,
// as the dotnet kernel does; a code that may not be sent back is answered
// with 1002 (protocol error).
func answerPeerClose(channel: in JWsChannel, payload: in slice[Byte]): Unit {
  val sent = if payload.length < 2 {
    try {
      val empty: JByteBuffer = JByteBuffer.allocate(0)
      JWebSockets.sendCloseBlocking(empty, channel)
      Ok(())
    } catch Exception as e {
      Err(e.message)
    }
  } else {
    val code = payload[0].toInt().and(255).shl(8).or(payload[1].toInt().and(255))
    val reason = bytesToUtf8Lenient(payload.slice(2, payload.length))
    if isSendableCloseCode(code) {
      sendCloseFrame(channel, code, reason)
    } else {
      sendCloseFrame(channel, 1002, "")
    }
  }
  // A send that fails means the peer is already gone; the close listener
  // reports the closed connection either way.
  match sent {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func dispatchFrame(
  handle: in Int, connId: in String, channel: in JWsChannel, frame: in JWsStreamSourceFrameChannel
): Unit {
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
  } else if frameType == "CLOSE" {
    // The close listener reports the closed connection once Undertow has
    // both sent and received a close.
    answerPeerClose(channel, bytes)
  } else {
    // CONTINUATION (fragmented
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
      dispatchFrame(handle, connId, channel, frame)
      frame.close()
    }
  }
}

// ─── Connection lifecycle listeners ───────────────────────────────────────────
record WsReceiveListener {
  registryHandle: Int
  connId: String
}

// `ChannelListener<T extends Channel>.handleEvent(T)` erases to
// `handleEvent(java.nio.channels.Channel)`, and a Lyric `impl` emits no
// bridge method, so the listener must declare the erased parameter type:
// declaring `WebSocketChannel` made XNIO fail every event with
// `AbstractMethodError` (#7243).  The connection's `WebSocketChannel` comes
// from the registry instead.
func connectionChannel(handle: in Int, connId: in String): Option[JWsChannel] {
  val state = lookupRegistry(handle)
  if JObjects.isNull(state) {
    return None
  }
  val channel: JWsChannel = state.connMap.get(connId)
  if JObjects.isNull(channel) {
    None
  } else {
    Some(value = channel)
  }
}

impl JChannelListener for WsReceiveListener {
  func handleEvent(event: in JNioChannel): Unit {
    val channel = match connectionChannel(self.registryHandle, self.connId) { case Some(c) -> c; case None -> return }
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
  func handleEvent(event: in JNioChannel): Unit {
    val channel = match connectionChannel(self.registryHandle, self.connId) { case Some(c) -> c; case None -> return }
    val code: Int = channel.getCloseCode()
    val reasonRaw: String? = channel.getCloseReason()
    val reason: String = reasonRaw ?? ""
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

    val reqPathRaw: String? = exchange.getRequestURI()
    val reqPath: String = reqPathRaw ?? ""
    val reqQueryRaw: String? = exchange.getQueryString()
    val reqQuery: String = reqQueryRaw ?? ""
    val srcAddr: JInetSocketAddress = channel.getSourceAddress()
    val remoteAddress = if JObjects.isNull(srcAddr) { "" } else { srcAddr.toString() }
    invokeOnOpen(self.registryHandle, connId, reqPath, reqQuery, remoteAddress, handshakeHeaders(exchange))
  }
}

// The upgrade request's headers under lower-cased names, a repeated header's
// values joined with ", " — the same shape `Ws.Handshake` gives the dotnet
// kernel.
func handshakeHeaders(exchange: in JWsHttpExchange): Map[String, String] {
  val result: Map[String, String] = newMap()
  val raw: JJavaMap = exchange.getRequestHeaders()
  if JObjects.isNull(raw) {
    return result
  }
  val names: JJavaSet = raw.keySet()
  val it: JIterator = names.iterator()
  while it.hasNext() {
    val name: String = it.next()
    val values: JJavaList = raw.get(name)
    val joined: String = if JObjects.isNull(values) { "" } else { JStr.join(", ", values) }
    result[name.toLower()] = joined
  }
  result
}

record WsOriginGuard {
  allowedOrigins: slice[String]
  sameHostPorts: slice[Int]
  next: JWsHandshakeHandler
}

impl JHttpHandler for WsOriginGuard {
  func handleRequest(exchange: in JHttpServerExchange): Unit {
    val headers: JHeaderMap = exchange.getRequestHeaders()
    val originRaw: String? = headers.getFirst("Origin")
    val hostRaw: String? = headers.getFirst("Host")
    val origin: String = originRaw ?? ""
    val host: String = hostRaw ?? ""
    if originAllowedFor(origin, host, self.allowedOrigins, self.sameHostPorts) {
      self.next.handleRequest(exchange)
    } else {
      exchange.setStatusCode(403)
      val _ = exchange.endExchange()
    }
  }
}

// ─── Public kernel surface ─────────────────────────────────────────────────────
/// Create a WebSocket endpoint with no listener of its own: an HTTP server
/// mounts `endpointHandler(handle, ...)` at the endpoint's path on its own
/// Undertow listener.  Returns a registry handle usable with
/// `send`/`broadcast`/`close`/`connectionCount`/`isConnected`.
///
/// Callback signatures are kept primitive so this kernel never imports the
/// public `Ws` package's `WsHandler`/`WsContext`/`WsMessage` types (`ws.l` does
/// the translation, avoiding an import cycle):
///   onOpen(connectionId, path, query, remoteAddress, handshakeHeaders)
///   onMessage(connectionId, messageType, data)
///   onClose(connectionId, code, reason)
///   onError(connectionId, message)
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
    lock = JReentrantLock.new()
  )
  registryMap.put(handle.toString(), state)
  Ok(handle)
}

/// The Undertow handler that upgrades a request to the endpoint
/// `registryHandle` (from `createEndpoint`), behind the cross-site WebSocket
/// hijacking defence (#7243).  The caller routes only the endpoint's exact
/// path to it.
@stable(since = "0.3")
pub func endpointHandler(
  registryHandle: in Int, allowedOrigins: in slice[String], sameHostPorts: in slice[Int]
): JHttpHandler {
  val callback = WsConnectCallback(registryHandle = registryHandle)
  val handshakeHandler: JWsHandshakeHandler = JWsHandshakeHandler.new(callback)
  val guarded: JHttpHandler = WsOriginGuard(
    allowedOrigins = allowedOrigins,
    sameHostPorts = sameHostPorts,
    next = handshakeHandler
  )
  guarded
}

/// An endpoint has no listener of its own, so there is nothing to stop: the
/// HTTP server that mounts it owns the listener.
@stable(since = "0.1")
pub func stopServer(registryHandle: in Int): Result[Unit, String] {
  val state = lookupRegistry(registryHandle)
  if JObjects.isNull(state) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  Err("registry " + registryHandle.toString() + " has no running server")
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
