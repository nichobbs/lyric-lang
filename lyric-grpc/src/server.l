//! Grpc.Server — the gRPC server: HTTP/2 over `Std.TcpHost` and the stdlib's
//! sans-IO `Std.HttpEngine.H2Conn`, one pure-Lyric implementation for dotnet
//! and the JVM (docs/72 slice 8, D804; it began as the dotnet-only h2c server of
//! D287). Plaintext h2c (prior knowledge, what a gRPC client speaks to an
//! `http://` address) and TLS with ALPN `h2` (`startServerTls`, the same
//! `Std.Tls.TlsServerConfig` and mTLS policy as `Std.HttpServer`).
//!
//! `Grpc.AspNetCore` and grpc-java register an RPC through classes a Lyric
//! record cannot extend, so the server speaks the gRPC wire format itself
//! (`Grpc.Wire`: 5-byte length-prefixed messages, `grpc-status` /
//! `grpc-message` trailers). It is verified against `Grpc.Net.Client` and
//! grpc-java, implementations it shares no code with.
//!
//! Concurrency (`Std.HttpServerHost`, the per-target seam). One task reads each
//! connection; every call runs its handler on its own task, so a slow handler
//! blocks neither its connection nor others. A connection's HTTP/2 state and
//! socket writes are serialized by a mutex on its `ConnState`. A sender whose
//! flow-control window is empty releases the mutex and polls (2 ms) until the
//! peer opens it, the call is cancelled, or 30 s pass.
//!
//! Requests. One message per call (unary and server streaming), at most 4 MiB
//! after decompression (`ResourceExhausted` beyond, and a gzip body is expanded
//! under that bound, so a decompression bomb is refused before it is built).
//! `grpc-encoding` is `identity` or `gzip`; anything else is `Unimplemented`
//! with `grpc-accept-encoding` listing what is supported. Responses are never
//! compressed.
//!
//! Deadlines. A `grpc-timeout` is enforced: when it passes before the handler
//! has answered, the call ends with `DeadlineExceeded` at once, the handler's
//! later result is dropped, and a streaming handler's `emit` starts returning
//! `false`. A unary handler cannot be interrupted, so it runs to completion in
//! the background. The handler sees the time left at dispatch as a `grpc-timeout`
//! metadata entry (`Grpc.requestTimeoutMs`).
//!
//! Handler panics end the call with `Internal` and no detail (the message may
//! carry server internals); the connection and the server go on.
//!
//! No reflection (`reflectionEnabled = true` panics).
@io
package Grpc.Server

import Grpc.Types
import Grpc.Wire
import Std.Core
import Std.Collections
import Std.String as Str
import Std.Time
import Std.Tls
import Std.TcpHost
import Std.HttpServerHost
import Std.HttpEngine
import Std.HttpEngine.H2Conn as H2
import Std.HttpEngine.H2Frame

val maxRequestBytes: Int = 4194304

val sendWindowWaitMs: Long = 30000i64

val handshakeTimeoutMs: Int = 10000

/// What the server decodes: `grpc-accept-encoding` on an `Unimplemented`.
val supportedEncodings: String = "identity,gzip"

/// One call: the request as it arrives, and the flags the handler and deadline
/// tasks share. `responded` and `headersSent` are only touched under the
/// connection's mutex, so the handler task and the deadline task cannot both
/// end the call.
ref record Call {
  streamId: Int
  path: String
  metadata: List[GrpcMetadataEntry]
  encoding: String
  reader: MessageReader
  timeoutText: String
  timeoutBad: Bool
  var contentTypeOk: Bool
  var tooLarge: Bool
  var cancelled: Bool
  var headersSent: Bool
  var responded: Bool
  var finished: Bool
  deadlineAt: Long
}

ref record ConnState {
  id: Int
  conn: Conn
  h2: H2.H2Connection
  guard: Mutex
  calls: List[Call]
  var active: Int
  var open: Bool
}

ref record ServerState {
  listener: Listener
  registry: ServiceRegistry
  guard: Mutex
  tls: Option[ServerTls]
  maxIdleMs: Int
  port: Int
  conns: List[ConnState]
  var stopping: Bool
  var stopped: Bool
  var inflight: Int
  var nextConnId: Int
}

ref record ServerTable {
  guard: Mutex
  items: List[ServerState]
}

val serverTable: ServerTable = ServerTable(guard = newMutex(), items = newList())

// ─── Small helpers ────────────────────────────────────────────────────────────
func headerValue(headers: in List[HeaderField], name: in String): String {
  for h in headers {
    if h.name == name {
      return h.value
    }
  }
  ""
}

func isReservedHeader(name: in String): Bool {
  Str.startsWith(name, ":") or name == "content-type" or name == "te" or name == "user-agent" or
    Str.startsWith(name, "grpc-") or
    Str.endsWith(name, "-bin")
}

func requestMetadata(headers: in List[HeaderField]): List[GrpcMetadataEntry] {
  val entries: List[GrpcMetadataEntry] = newList()
  for h in headers {
    if not isReservedHeader(h.name) {
      entries.add(GrpcMetadataEntry(key = h.name, value = h.value))
    }
  }
  entries
}

/// `grpc-message` as an HTTP/2 field value: percent-encoded, and with any
/// leading or trailing space escaped too (HTTP/2 forbids both in a value).
func messageField(message: in String): String {
  var encoded = Types.encodeGrpcMessage(message)
  if Str.startsWith(encoded, " ") {
    encoded = "%20" + Str.substring(encoded, 1)
  }
  if Str.endsWith(encoded, " ") {
    encoded = Str.substring(encoded, 0, encoded.length - 1) + "%20"
  }
  encoded
}

func statusFields(status: in GrpcStatus): List[HeaderField] {
  val fields: List[HeaderField] = newList()
  fields.add(HeaderField(name = "grpc-status", value = Types.statusCodeToInt(status.code).toString()))
  if status.message.length > 0 {
    fields.add(HeaderField(name = "grpc-message", value = messageField(status.message)))
  }
  fields
}

func okStatus(): GrpcStatus {
  GrpcStatus(code = GrpcStatusCode.Ok, message = "")
}

func failure(code: in GrpcStatusCode, message: in String): GrpcStatus {
  GrpcStatus(code = code, message = message)
}

func minInt(a: in Int, b: in Int): Int {
  if a < b {
    a
  } else {
    b
  }
}

// ─── Wire output (each takes the connection mutex) ────────────────────────────
func writeLocked(cs: in ConnState, bytes: in slice[Byte]): Unit {
  if bytes.length > 0 and cs.open {
    match hostWrite(cs.conn, bytes) {
      case Std.Core.Ok(_) -> ()
      case Std.Core.Err(_) -> {
        cs.open = false
      }
    }
  }
}

func initialHeaders(): List[HeaderField] {
  val hs: List[HeaderField] = newList()
  hs.add(HeaderField(name = ":status", value = "200"))
  hs.add(HeaderField(name = "content-type", value = "application/grpc"))
  hs
}

/// Send the response HEADERS once. `false` when the call has already been
/// ended (a deadline, a cancellation) or the connection is gone.
func ensureHeaders(cs: in ConnState, call: in Call): Bool {
  lock(cs.guard)
  defer {
    unlock(cs.guard)
  }
  if call.responded or not cs.open {
    return false
  }
  if call.headersSent {
    return true
  }
  match H2.encodeResponseHeaders(cs.h2, call.streamId, initialHeaders(), false) {
    case Std.Core.Ok(bytes) -> {
      writeLocked(cs, bytes)
      call.headersSent = cs.open
      cs.open
    }
    case Std.Core.Err(_) -> false
  }
}

/// End the call with `status` (and `extra` fields on a trailers-only answer).
/// The first caller wins: `false` when the call had already been ended.
func finishCall(cs: in ConnState, call: in Call, status: in GrpcStatus, extra: in List[HeaderField]): Bool {
  lock(cs.guard)
  defer {
    unlock(cs.guard)
  }
  if call.responded or not cs.open {
    return false
  }
  call.responded = true
  if call.headersSent {
    match H2.encodeResponseTrailers(cs.h2, call.streamId, statusFields(status)) {
      case Std.Core.Ok(bytes) -> writeLocked(cs, bytes)
      case Std.Core.Err(_) -> ()
    }
  } else {
    val hs = initialHeaders()
    for f in statusFields(status) {
      hs.add(f)
    }
    for f in extra {
      hs.add(f)
    }
    match H2.encodeResponseHeaders(cs.h2, call.streamId, hs, true) {
      case Std.Core.Ok(bytes) -> writeLocked(cs, bytes)
      case Std.Core.Err(_) -> ()
    }
  }
  true
}

func finishWith(cs: in ConnState, call: in Call, status: in GrpcStatus): Unit {
  val none: List[HeaderField] = newList()
  val _ = finishCall(cs, call, status, none)
}

func rejectContentType(cs: in ConnState, call: in Call): Unit {
  lock(cs.guard)
  defer {
    unlock(cs.guard)
  }
  if call.responded or not cs.open {
    return
  }
  call.responded = true
  val hs: List[HeaderField] = newList()
  hs.add(HeaderField(name = ":status", value = "415"))
  match H2.encodeResponseHeaders(cs.h2, call.streamId, hs, true) {
    case Std.Core.Ok(bytes) -> writeLocked(cs, bytes)
    case Std.Core.Err(_) -> ()
  }
}

/// Frame `data` onto the stream in window-sized DATA frames, waiting for the
/// peer's WINDOW_UPDATEs when its window is empty.
func sendData(cs: in ConnState, call: in Call, data: in slice[Byte]): Bool {
  var offset = 0
  val giveUpAt = Std.Time.nowEpochMillis() + sendWindowWaitMs
  while offset < data.length {
    if call.cancelled or not cs.open {
      return false
    }
    var progressed = false
    lock(cs.guard)
    if call.responded {
      unlock(cs.guard)
      return false
    }
    val room = H2.maxSendableOnStream(cs.h2, call.streamId)
    val frame = minInt(room, H2.peerMaxFrameSize(cs.h2))
    val chunk = minInt(frame, data.length - offset)
    if chunk > 0 {
      match H2.sendData(cs.h2, call.streamId, data.slice(offset, offset + chunk), false) {
        case Std.Core.Ok(bytes) -> {
          writeLocked(cs, bytes)
          offset = offset + chunk
          progressed = true
        }
        case Std.Core.Err(_) -> {
          call.cancelled = true
        }
      }
    }
    unlock(cs.guard)
    if not progressed {
      if Std.Time.nowEpochMillis() > giveUpAt {
        return false
      }
      sleepMillis(2)
    }
  }
  true
}

func sendMessage(cs: in ConnState, call: in Call, message: in slice[Byte]): Bool {
  ensureHeaders(cs, call) and sendData(cs, call, Wire.frameMessage(message, false))
}

// ─── Running a call ───────────────────────────────────────────────────────────
record MethodPath {
  service: String
  method: String
}

func splitPath(path: in String): Option[MethodPath] {
  if not Str.startsWith(path, "/") {
    return None
  }
  val rest = Str.substring(path, 1)
  val slash = Str.indexOfRaw(rest, "/")
  if slash <= 0 or slash == rest.length - 1 {
    return None
  }
  Some(value = MethodPath(service = Str.substring(rest, 0, slash), method = Str.substring(rest, slash + 1)))
}

/// The metadata a handler receives: the request's custom headers, plus a
/// `grpc-timeout` entry with the time left at dispatch when the call has a
/// deadline.
func handlerMetadata(call: in Call, leftMs: in Long): slice[GrpcMetadataEntry] {
  val entries: List[GrpcMetadataEntry] = newList()
  for m in call.metadata {
    entries.add(m)
  }
  if call.timeoutText != "" {
    val clamped = if leftMs > 2147483647i64 { 2147483647i64 } else { leftMs }
    entries.add(GrpcMetadataEntry(key = "grpc-timeout", value = Wire.encodeTimeout(clamped.toInt())))
  }
  entries.toArray()
}

func runUnary(
  cs: in ConnState,
  call: in Call,
  handle: in (slice[Byte], slice[GrpcMetadataEntry]) -> Result[slice[Byte], GrpcStatus],
  request: in slice[Byte],
  meta: in slice[GrpcMetadataEntry],
): Unit {
  match handle(request, meta) {
    case Std.Core.Ok(response) -> {
      if sendMessage(cs, call, response) {
        finishWith(cs, call, okStatus())
      }
    }
    case Std.Core.Err(status) -> finishWith(cs, call, status)
  }
}

func runStreaming(
  cs: in ConnState,
  call: in Call,
  handle: in (slice[Byte], slice[GrpcMetadataEntry], (slice[Byte]) -> Bool) -> Result[Unit, GrpcStatus],
  request: in slice[Byte],
  meta: in slice[GrpcMetadataEntry],
): Unit {
  val emit = { m: slice[Byte] -> if call.cancelled or not cs.open { false } else { sendMessage(cs, call, m) } }
  match handle(request, meta, emit) {
    case Std.Core.Ok(_) -> {
      if ensureHeaders(cs, call) {
        finishWith(cs, call, okStatus())
      }
    }
    case Std.Core.Err(status) -> finishWith(cs, call, status)
  }
}

/// Ends the call with `DeadlineExceeded` when its deadline passes before the
/// handler has answered, and cancels it so a streaming handler stops emitting.
func watchDeadline(cs: in ConnState, call: in Call): Unit {
  while not call.finished {
    val left = call.deadlineAt - Std.Time.nowEpochMillis()
    if left <= 0i64 {
      val none: List[HeaderField] = newList()
      if finishCall(cs, call, failure(GrpcStatusCode.DeadlineExceeded, "deadline exceeded"), none) {
        call.cancelled = true
      }
      return
    }
    sleepMillis(if left < 10i64 { left.toInt() } else { 10 })
  }
}

func dispatch(cs: in ConnState, call: in Call, handler: in GrpcHandler, request: in slice[Byte]): Unit {
  var meta = handlerMetadata(call, 1i64)
  if call.timeoutText != "" {
    val left = call.deadlineAt - Std.Time.nowEpochMillis()
    if left < 1i64 {
      finishWith(cs, call, failure(GrpcStatusCode.DeadlineExceeded, "deadline exceeded"))
      return
    }
    meta = handlerMetadata(call, left)
    startTask({ -> watchDeadline(cs, call) })
  }
  match handler {
    case GrpcHandler.Unary(handle) -> runUnary(cs, call, handle, request, meta)
    case GrpcHandler.ServerStreaming(handle) -> runStreaming(cs, call, handle, request, meta)
  }
}

func encodingSupported(encoding: in String): Bool {
  val e = Str.toLower(encoding)
  e == "" or e == "identity" or e == "gzip" or e == "x-gzip"
}

/// The one request message of a call, decompressed, or the status that ends it.
func requestMessage(call: in Call): Result[slice[Byte], GrpcStatus] {
  match readerPoll(call.reader) {
    case WireMessage(compressed, payload) -> {
      match readerPoll(call.reader) {
        case WireNeedMore -> ()
        case _ -> return Std.Core.Err(failure(GrpcStatusCode.InvalidArgument, "expected exactly one request message"))
      }
      if readerBuffered(call.reader) > 0 {
        return Std.Core.Err(failure(GrpcStatusCode.InvalidArgument, "expected exactly one request message"))
      }
      if compressed {
        Wire.decompressMessage(call.encoding, payload, maxRequestBytes)
      } else {
        Std.Core.Ok(payload)
      }
    }
    case WireNeedMore -> Std.Core.Err(failure(GrpcStatusCode.InvalidArgument, "expected exactly one request message"))
    case WireTooLarge(_) -> Std.Core.Err(
      failure(GrpcStatusCode.ResourceExhausted, "request message is larger than 4 MiB")
    )
    case WireBadFlag(flag) -> Std.Core.Err(
      failure(
        GrpcStatusCode.Internal,
        "malformed message prefix: compressed flag " + flag.toString()
      )
    )
  }
}

func execute(server: in ServerState, cs: in ConnState, call: in Call): Unit {
  if not call.contentTypeOk {
    rejectContentType(cs, call)
    return
  }
  if server.stopping {
    finishWith(cs, call, failure(GrpcStatusCode.Unavailable, "server is shutting down"))
    return
  }
  if call.timeoutBad {
    finishWith(cs, call, failure(GrpcStatusCode.Internal, "malformed grpc-timeout '" + call.timeoutText + "'"))
    return
  }
  if not encodingSupported(call.encoding) {
    val accept: List[HeaderField] = newList()
    accept.add(HeaderField(name = "grpc-accept-encoding", value = supportedEncodings))
    val _ = finishCall(
      cs,
      call,
      failure(
        GrpcStatusCode.Unimplemented,
        "unsupported grpc-encoding '" + call.encoding + "' (supported: " + supportedEncodings + ")"
      ),
      accept
    )
    return
  }
  if call.tooLarge {
    finishWith(cs, call, failure(GrpcStatusCode.ResourceExhausted, "request message is larger than 4 MiB"))
    return
  }
  val route = match splitPath(call.path) {
    case Some(parts) -> Types.findRoute(server.registry, parts.service, parts.method)
    case None -> None
  }
  match route {
    case None -> finishWith(cs, call, failure(GrpcStatusCode.Unimplemented, "unknown method " + call.path))
    case Some(r) -> {
      match requestMessage(call) {
        case Std.Core.Err(status) -> finishWith(cs, call, status)
        case Std.Core.Ok(request) -> dispatch(cs, call, r.handler, request)
      }
    }
  }
}

func removeCall(cs: in ConnState, call: in Call): Unit {
  lock(cs.guard)
  defer {
    unlock(cs.guard)
  }
  var i = 0
  while i < cs.calls.count {
    val c: Call = cs.calls[i]
    if c.streamId == call.streamId {
      cs.calls.removeAt(i)
      break
    }
    i = i + 1
  }
  cs.active = cs.active - 1
}

func runCall(server: in ServerState, cs: in ConnState, call: in Call): Unit {
  lock(server.guard)
  server.inflight = server.inflight + 1
  unlock(server.guard)
  defer {
    call.finished = true
    lock(server.guard)
    server.inflight = server.inflight - 1
    unlock(server.guard)
    removeCall(cs, call)
  }
  runGuarded(
    { -> execute(server, cs, call) },
    { _ ->
      // A handler panic reaches the client as INTERNAL with no detail: the
      // message may carry server internals.
      runGuarded({ -> finishWith(cs, call, failure(GrpcStatusCode.Internal, "handler panicked")) }, { _ -> () })
    }
  )
}

// ─── Reading a connection ─────────────────────────────────────────────────────
func findCall(cs: in ConnState, streamId: in Int): Option[Call] {
  for c in cs.calls {
    if c.streamId == streamId {
      return Some(value = c)
    }
  }
  None
}

func creditWindows(cs: in ConnState, streamId: in Int, wireLength: in Int, endStream: in Bool): Unit {
  if wireLength > 0 {
    writeLocked(cs, H2.grantConnectionWindow(cs.h2, wireLength))
    if not endStream {
      writeLocked(cs, H2.grantStreamWindow(cs.h2, streamId, wireLength))
    }
  }
}

func onHeaders(
  cs: in ConnState,
  streamId: in Int,
  headers: in List[HeaderField],
  endStream: in Bool,
  ready: in List[Call],
): Unit {
  match findCall(cs, streamId) {
    case Some(_) -> ()
    case None -> {
      val timeoutText = headerValue(headers, "grpc-timeout")
      var timeoutMs = 0i64
      var timeoutBad = false
      if timeoutText != "" {
        match Wire.parseTimeout(timeoutText) {
          case Some(ms) -> {
            timeoutMs = ms
          }
          case None -> {
            timeoutBad = true
          }
        }
      }
      val call = Call(
        streamId = streamId,
        path = headerValue(headers, ":path"),
        metadata = requestMetadata(headers),
        encoding = headerValue(headers, "grpc-encoding"),
        reader = newMessageReader(maxRequestBytes),
        timeoutText = timeoutText,
        timeoutBad = timeoutBad,
        contentTypeOk = Wire.isGrpcContentType(headerValue(headers, "content-type")),
        tooLarge = false,
        cancelled = false,
        headersSent = false,
        responded = false,
        finished = false,
        deadlineAt = Std.Time.nowEpochMillis() + timeoutMs
      )
      cs.calls.add(call)
      if endStream {
        cs.active = cs.active + 1
        ready.add(call)
      }
    }
  }
}

func onData(
  cs: in ConnState,
  streamId: in Int,
  data: in slice[Byte],
  endStream: in Bool,
  wireLength: in Int,
  ready: in List[Call],
): Unit {
  creditWindows(cs, streamId, wireLength, endStream)
  match findCall(cs, streamId) {
    case None -> ()
    case Some(call) -> {
      if not call.tooLarge {
        readerFeed(call.reader, data)
        if readerBuffered(call.reader) > maxRequestBytes + 5 {
          call.tooLarge = true
        }
      }
      if endStream {
        cs.active = cs.active + 1
        ready.add(call)
      }
    }
  }
}

func onEvent(cs: in ConnState, ev: in H2.H2Event, ready: in List[Call]): Unit {
  match ev {
    case H2.H2RequestHeaders(streamId, headers, endStream) -> onHeaders(cs, streamId, headers, endStream, ready)
    case H2.H2RequestData(streamId, data, endStream, wireLength) -> onData(
      cs,
      streamId,
      data,
      endStream,
      wireLength,
      ready
    )
    case H2.H2PeerReset(streamId, _) -> {
      match findCall(cs, streamId) {
        case Some(call) -> {
          call.cancelled = true
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
}

/// Feed received bytes to the connection and collect the calls they complete.
func process(cs: in ConnState, bytes: in slice[Byte]): List[Call] {
  val ready: List[Call] = newList()
  lock(cs.guard)
  defer {
    unlock(cs.guard)
  }
  val r = H2.feed(cs.h2, bytes)
  writeLocked(cs, r.outbound)
  for ev in r.events {
    onEvent(cs, ev, ready)
  }
  ready
}

func serveConnection(server: in ServerState, conn: in Conn): Unit {
  val h2 = H2.newServerConnection(H2.h2DefaultServerSettings())
  lock(server.guard)
  if server.stopping {
    unlock(server.guard)
    hostClose(conn)
    return
  }
  server.nextConnId = server.nextConnId + 1
  val cs = ConnState(
    id = server.nextConnId,
    conn = conn,
    h2 = h2,
    guard = newMutex(),
    calls = newList(),
    active = 0,
    open = true
  )
  server.conns.add(cs)
  unlock(server.guard)
  hostSetIoTimeout(conn, server.maxIdleMs)
  lock(cs.guard)
  writeLocked(cs, H2.serverInitialFrame(h2))
  unlock(cs.guard)
  var failures = 0
  while cs.open and not H2.isFailed(h2) {
    match hostRead(conn, 65536) {
      case Std.Core.Err(_) -> {
        // The idle timeout is a read error too; a connection with calls in
        // flight is not idle, so keep it unless the errors repeat.
        failures = failures + 1
        if cs.active == 0 or failures >= 3 {
          cs.open = false
        } else {
          sleepMillis(20)
        }
      }
      case Std.Core.Ok(bytes) -> {
        failures = 0
        if bytes.length == 0 {
          cs.open = false
        } else {
          for call in process(cs, bytes) {
            startTask({ -> runCall(server, cs, call) })
          }
        }
      }
    }
  }
  lock(cs.guard)
  cs.open = false
  for c in cs.calls {
    c.cancelled = true
  }
  unlock(cs.guard)
  hostClose(conn)
  forgetConnection(server, cs)
}

/// A finished connection must not stay reachable from the server: it holds the
/// HTTP/2 state, the call list and the socket wrapper.
func forgetConnection(server: in ServerState, cs: in ConnState): Unit {
  lock(server.guard)
  defer {
    unlock(server.guard)
  }
  var i = 0
  while i < server.conns.count {
    val c: ConnState = server.conns[i]
    if c.id == cs.id {
      server.conns.removeAt(i)
      break
    }
    i = i + 1
  }
}

/// Terminate TLS on an accepted socket on this connection's own task, so one
/// slow handshake never holds up the accept loop. A client that did not
/// negotiate `h2` is refused: gRPC needs HTTP/2.
func serveTlsConnection(server: in ServerState, plain: in Conn, tls: in ServerTls): Unit {
  match hostUpgradeServerTlsPrepared(plain, tls, handshakeTimeoutMs) {
    case Std.Core.Err(_) -> hostClose(plain)
    case Std.Core.Ok(conn) -> {
      val alpn = hostAlpn(conn)
      if alpn == "" or alpn == "h2" {
        serveConnection(server, conn)
      } else {
        hostClose(conn)
      }
    }
  }
}

// Two monomorphic accept loops rather than one that branches on an
// `Option[ServerTls]`: `Std.HttpServer` splits its loops the same way, because
// an `Option` over an extern payload threaded through a task closure degrades in
// a multi-package bundle build.
func plainAcceptLoop(server: in ServerState): Unit {
  var running = true
  while running {
    match hostAccept(server.listener) {
      case Std.Core.Ok(conn) -> {
        if server.stopping {
          hostClose(conn)
        } else {
          startTask({ -> serveConnection(server, conn) })
        }
      }
      case Std.Core.Err(_) -> {
        if server.stopping {
          running = false
        } else {
          sleepMillis(50)
        }
      }
    }
  }
}

func tlsAcceptLoop(server: in ServerState, tls: in ServerTls): Unit {
  var running = true
  while running {
    match hostAccept(server.listener) {
      case Std.Core.Ok(conn) -> {
        if server.stopping {
          hostClose(conn)
        } else {
          startTask({ -> serveTlsConnection(server, conn, tls) })
        }
      }
      case Std.Core.Err(_) -> {
        if server.stopping {
          running = false
        } else {
          sleepMillis(50)
        }
      }
    }
  }
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────
func openServer(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
  tls: in Option[ServerTls],
): ServerState {
  if reflectionEnabled {
    panic("gRPC server reflection is not supported: set GrpcServer.reflectionEnabled to false")
  }
  ensureThreadCapacity(defaultMaxConnections())
  match hostListen(host, port) {
    case Std.Core.Err(e) -> panic(
      "gRPC server could not start on " + host + ":" + port.toString() + ": " +
        TcpError.message(e)
    )
    case Std.Core.Ok(listener) -> {
      ServerState(
        listener = listener,
        registry = registry,
        guard = newMutex(),
        tls = tls,
        maxIdleMs = maxConnectionIdleMs,
        port = hostLocalPort(listener),
        conns = newList(),
        stopping = false,
        stopped = false,
        inflight = 0,
        nextConnId = 0
      )
    }
  }
}

func prepareTls(tls: in TlsServerConfig): ServerTls {
  match hostPrepareServerTls(tls) {
    case Std.Core.Ok(state) -> state
    case Std.Core.Err(e) -> panic("gRPC server TLS configuration is not usable: " + TcpError.message(e))
  }
}

/// Serve plaintext h2c on the calling thread until the process exits.
pub func serve(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): Unit {
  val none: Option[ServerTls] = None
  plainAcceptLoop(openServer(host, port, reflectionEnabled, maxConnectionIdleMs, registry, none))
}

/// Serve TLS (ALPN `h2`) on the calling thread until the process exits.
pub func serveTls(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
  tls: in TlsServerConfig,
): Unit {
  val state = prepareTls(tls)
  val some: Option[ServerTls] = Some(value = state)
  tlsAcceptLoop(openServer(host, port, reflectionEnabled, maxConnectionIdleMs, registry, some), state)
}

func register(server: in ServerState): GrpcServerHandle {
  lock(serverTable.guard)
  serverTable.items.add(server)
  val id = serverTable.items.count
  unlock(serverTable.guard)
  Types.wrapServerHandle(id)
}

pub func startServer(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): GrpcServerHandle {
  val none: Option[ServerTls] = None
  val server = openServer(host, port, reflectionEnabled, maxConnectionIdleMs, registry, none)
  startTask({ -> plainAcceptLoop(server) })
  register(server)
}

pub func startServerTls(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
  tls: in TlsServerConfig,
): GrpcServerHandle {
  val state = prepareTls(tls)
  val some: Option[ServerTls] = Some(value = state)
  val server = openServer(host, port, reflectionEnabled, maxConnectionIdleMs, registry, some)
  startTask({ -> tlsAcceptLoop(server, state) })
  register(server)
}

func lookup(handle: in GrpcServerHandle): Option[ServerState] {
  lock(serverTable.guard)
  defer {
    unlock(serverTable.guard)
  }
  val index = Types.serverHandleId(handle) - 1
  if index >= 0 and index < serverTable.items.count {
    Some(value = serverTable.items[index])
  } else {
    None
  }
}

/// The port the server is bound to; `0` once it has been stopped.
pub func serverPort(handle: in GrpcServerHandle): Int {
  match lookup(handle) {
    case Some(server) -> if server.stopped { 0 } else { server.port }
    case None -> 0
  }
}

func inflightCalls(server: in ServerState): Int {
  lock(server.guard)
  defer {
    unlock(server.guard)
  }
  server.inflight
}

/// The connections the server currently tracks (open ones; a closed
/// connection is forgotten). `0` for an unknown handle.
pub func trackedConnections(handle: in GrpcServerHandle): Int {
  match lookup(handle) {
    case Some(server) -> {
      lock(server.guard)
      defer {
        unlock(server.guard)
      }
      server.conns.count
    }
    case None -> 0
  }
}

/// Stop accepting connections and calls, wait up to `drainTimeoutMs` for the
/// calls in flight, then close every connection. A second stop is a no-op.
pub func stopServer(handle: in GrpcServerHandle, drainTimeoutMs: in Int): Unit {
  match lookup(handle) {
    case None -> ()
    case Some(server) -> {
      lock(server.guard)
      val first = not server.stopping
      server.stopping = true
      unlock(server.guard)
      if first {
        hostStopListener(server.listener)
        lock(server.guard)
        val draining = server.conns.toArray()
        unlock(server.guard)
        for cs in draining {
          // Tell each client to start no new call (RFC 9113 section 6.8) while
          // the calls in flight finish; closing without it reads as a crash.
          lock(cs.guard)
          writeLocked(cs, H2.sendGoAway(cs.h2, H2NoError))
          unlock(cs.guard)
        }
        val giveUpAt = Std.Time.nowEpochMillis() + drainTimeoutMs.toLong()
        while inflightCalls(server) > 0 and Std.Time.nowEpochMillis() < giveUpAt {
          sleepMillis(10)
        }
        lock(server.guard)
        val conns = server.conns.toArray()
        unlock(server.guard)
        for cs in conns {
          lock(cs.guard)
          cs.open = false
          unlock(cs.guard)
          hostClose(cs.conn)
        }
        lock(server.guard)
        server.conns.clear()
        server.stopped = true
        unlock(server.guard)
        match server.tls {
          case Some(state) -> hostReleaseServerTls(state)
          case None -> ()
        }
      }
    }
  }
}
