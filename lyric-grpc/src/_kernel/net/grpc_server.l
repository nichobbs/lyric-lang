//! Grpc.Kernel.Net.Server — the .NET gRPC server: plaintext HTTP/2 (h2c with
//! prior knowledge, which is what gRPC clients speak to an `http://` address)
//! over `Std.TcpHost` and the stdlib's sans-IO `Std.HttpEngine.H2Conn`.
//!
//! `Grpc.AspNetCore` registers an RPC through `BindableService` /
//! `ServiceBinderBase`, abstract classes a Lyric record cannot extend, so the
//! server speaks the gRPC wire format itself (5-byte length-prefixed messages,
//! `grpc-status` / `grpc-message` trailers). It is verified against
//! `Grpc.Net.Client`, an implementation it shares no code with.
//!
//! Concurrency. One task reads each connection; every call runs its handler on
//! its own task, so a slow handler blocks neither its connection nor others.
//! A connection's HTTP/2 state and socket writes are serialized by a monitor on
//! its `ConnState`. A sender whose flow-control window is empty releases the
//! monitor and polls (2 ms) until the peer opens it, the call is cancelled, or
//! 30 s pass.
//!
//! Limits. Request messages: one per call, uncompressed, at most 4 MiB
//! (`ResourceExhausted` beyond). `grpc-timeout` is not enforced server side: a
//! handler runs to completion and the client's deadline cancels the call from its
//! end. No TLS and no reflection (`reflectionEnabled = true` panics).
//!
//! Only active when compiled with feature = "dotnet" (D284).
@cfg(feature = "dotnet")
@io
package Grpc.Kernel.Net.Server

import Grpc.Types
import Std.Core
import Std.Collections
import Std.String as Str
import Std.Time
import Std.TcpHost
import Std.HttpEngine
import Std.HttpEngine.H2Conn as H2

extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@axiom("System.Threading.Monitor.Enter — acquires an exclusive lock on obj")
@externStatic
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@axiom("System.Threading.Monitor.Exit — releases an exclusive lock on obj")
@externStatic
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

val maxRequestBytes: Int = 4194304

val sendWindowWaitMs: Long = 30000i64

/// One call: the request as it arrives, and the flags the handler task reads.
ref record Call {
  streamId: Int
  path: String
  metadata: List[GrpcMetadataEntry]
  body: List[Byte]
  var contentTypeOk: Bool
  var encodingOk: Bool
  var tooLarge: Bool
  var cancelled: Bool
}

ref record ConnState {
  id: Int
  conn: Conn
  h2: H2.H2Connection
  calls: List[Call]
  var active: Int
  var open: Bool
}

ref record ServerState {
  listener: Listener
  registry: ServiceRegistry
  maxIdleMs: Int
  port: Int
  conns: List[ConnState]
  var stopping: Bool
  var stopped: Bool
  var inflight: Int
  var nextConnId: Int
}

ref record ServerTable {
  items: List[ServerState]
}

val serverTable: ServerTable = ServerTable(items = newList())

// ─── Small helpers ────────────────────────────────────────────────────────────
func headerValue(headers: in List[HeaderField], name: in String): String {
  for h in headers {
    if h.name == name {
      return h.value
    }
  }
  ""
}

func hasHeader(headers: in List[HeaderField], name: in String): Bool {
  for h in headers {
    if h.name == name {
      return true
    }
  }
  false
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

func frameMessage(message: in slice[Byte]): slice[Byte] {
  val n = message.length
  val acc: List[Byte] = newList()
  acc.add(0.toByte())
  acc.add(n.shr(24).and(255).toByte())
  acc.add(n.shr(16).and(255).toByte())
  acc.add(n.shr(8).and(255).toByte())
  acc.add(n.and(255).toByte())
  for b in message {
    acc.add(b)
  }
  acc.toArray()
}

/// Whether the framed request body is exactly one uncompressed message, and
/// where it ends.
func singleMessageLength(body: in slice[Byte]): Int {
  if body.length < 5 {
    return -1
  }
  if body[0].toInt() != 0 {
    return -2
  }
  val n = body[1].toInt().shl(24).or(body[2].toInt().shl(16)).or(body[3].toInt().shl(8)).or(body[4].toInt())
  if n < 0 or body.length != 5 + n {
    return -1
  }
  n
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

// ─── Wire output (each takes the connection monitor) ──────────────────────────
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

func sendHeaders(cs: in ConnState, streamId: in Int, headers: in List[HeaderField], endStream: in Bool): Bool {
  monitorEnter(cs)
  defer {
    monitorExit(cs)
  }
  match H2.encodeResponseHeaders(cs.h2, streamId, headers, endStream) {
    case Std.Core.Ok(bytes) -> {
      writeLocked(cs, bytes)
      cs.open
    }
    case Std.Core.Err(_) -> false
  }
}

func sendTrailers(cs: in ConnState, streamId: in Int, status: in GrpcStatus): Bool {
  monitorEnter(cs)
  defer {
    monitorExit(cs)
  }
  match H2.encodeResponseTrailers(cs.h2, streamId, statusFields(status)) {
    case Std.Core.Ok(bytes) -> {
      writeLocked(cs, bytes)
      cs.open
    }
    case Std.Core.Err(_) -> false
  }
}

func initialHeaders(): List[HeaderField] {
  val hs: List[HeaderField] = newList()
  hs.add(HeaderField(name = ":status", value = "200"))
  hs.add(HeaderField(name = "content-type", value = "application/grpc"))
  hs
}

/// A trailers-only response: one HEADERS block that carries the status.
func sendTrailersOnly(cs: in ConnState, streamId: in Int, status: in GrpcStatus): Bool {
  val hs = initialHeaders()
  for f in statusFields(status) {
    hs.add(f)
  }
  sendHeaders(cs, streamId, hs, true)
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
    monitorEnter(cs)
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
    monitorExit(cs)
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
  sendData(cs, call, frameMessage(message))
}

// ─── Running a call ───────────────────────────────────────────────────────────
ref record Flag {
  var value: Bool
}

record MethodPath {
  service: String
  method: String
}

func minInt(a: in Int, b: in Int): Int {
  if a < b {
    a
  } else {
    b
  }
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

func runUnary(
  cs: in ConnState,
  call: in Call,
  handle: in (slice[Byte], slice[GrpcMetadataEntry]) -> Result[slice[Byte], GrpcStatus],
  request: in slice[Byte],
): Unit {
  match handle(request, call.metadata.toArray()) {
    case Std.Core.Ok(response) -> {
      if sendHeaders(cs, call.streamId, initialHeaders(), false) {
        if sendMessage(cs, call, response) {
          val _ = sendTrailers(cs, call.streamId, okStatus())
        }
      }
    }
    case Std.Core.Err(status) -> {
      val _ = sendTrailersOnly(cs, call.streamId, status)
    }
  }
}

func runStreaming(
  cs: in ConnState,
  call: in Call,
  handle: in (slice[Byte], slice[GrpcMetadataEntry], (slice[Byte]) -> Bool) -> Result[Unit, GrpcStatus],
  request: in slice[Byte],
): Unit {
  val headersSent = Flag(value = false)
  val emit = { m: slice[Byte] ->
    if call.cancelled or not cs.open {
      false
    } else {
      if not headersSent.value {
        headersSent.value = sendHeaders(cs, call.streamId, initialHeaders(), false)
      }
      headersSent.value and sendMessage(cs, call, m)
    }
  }
  val result = handle(request, call.metadata.toArray(), emit)
  match result {
    case Std.Core.Ok(_) -> {
      if not headersSent.value {
        headersSent.value = sendHeaders(cs, call.streamId, initialHeaders(), false)
      }
      if headersSent.value {
        val _ = sendTrailers(cs, call.streamId, okStatus())
      }
    }
    case Std.Core.Err(status) -> {
      if headersSent.value {
        val _ = sendTrailers(cs, call.streamId, status)
      } else {
        val _ = sendTrailersOnly(cs, call.streamId, status)
      }
    }
  }
}

func execute(server: in ServerState, cs: in ConnState, call: in Call): Unit {
  if not call.contentTypeOk {
    val hs: List[HeaderField] = newList()
    hs.add(HeaderField(name = ":status", value = "415"))
    val _ = sendHeaders(cs, call.streamId, hs, true)
    return
  }
  if server.stopping {
    val _ = sendTrailersOnly(cs, call.streamId, failure(GrpcStatusCode.Unavailable, "server is shutting down"))
    return
  }
  if not call.encodingOk {
    val _ = sendTrailersOnly(
      cs,
      call.streamId,
      failure(GrpcStatusCode.Unimplemented, "message compression is not supported")
    )
    return
  }
  if call.tooLarge {
    val _ = sendTrailersOnly(
      cs,
      call.streamId,
      failure(GrpcStatusCode.ResourceExhausted, "request message is larger than 4 MiB")
    )
    return
  }
  val route = match splitPath(call.path) {
    case Some(parts) -> Types.findRoute(server.registry, parts.service, parts.method)
    case None -> None
  }
  match route {
    case None -> {
      val _ = sendTrailersOnly(cs, call.streamId, failure(GrpcStatusCode.Unimplemented, "unknown method " + call.path))
    }
    case Some(r) -> {
      val body = call.body.toArray()
      val n = singleMessageLength(body)
      if n == -2 {
        val _ = sendTrailersOnly(
          cs,
          call.streamId,
          failure(GrpcStatusCode.Unimplemented, "message compression is not supported")
        )
      } else if n < 0 {
        val _ = sendTrailersOnly(
          cs,
          call.streamId,
          failure(GrpcStatusCode.InvalidArgument, "expected exactly one request message")
        )
      } else {
        val request = body.slice(5, 5 + n)
        match r.handler {
          case GrpcHandler.Unary(handle) -> runUnary(cs, call, handle, request)
          case GrpcHandler.ServerStreaming(handle) -> runStreaming(cs, call, handle, request)
        }
      }
    }
  }
}

func removeCall(cs: in ConnState, call: in Call): Unit {
  monitorEnter(cs)
  defer {
    monitorExit(cs)
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
  monitorEnter(server)
  server.inflight = server.inflight + 1
  monitorExit(server)
  defer {
    monitorEnter(server)
    server.inflight = server.inflight - 1
    monitorExit(server)
    removeCall(cs, call)
  }
  try {
    execute(server, cs, call)
  } catch Bug as _ {
    // A handler panic reaches the client as INTERNAL with no detail: the
    // message may carry server internals.
    try {
      val _ = sendTrailersOnly(cs, call.streamId, failure(GrpcStatusCode.Internal, "handler panicked"))
    } catch Bug as _ {
      ()
    }
  }
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
      val encoding = headerValue(headers, "grpc-encoding")
      val call = Call(
        streamId = streamId,
        path = headerValue(headers, ":path"),
        metadata = requestMetadata(headers),
        body = newList(),
        contentTypeOk = Str.startsWith(headerValue(headers, "content-type"), "application/grpc"),
        encodingOk = encoding == "" or encoding == "identity",
        tooLarge = false,
        cancelled = false
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
        for b in data {
          call.body.add(b)
        }
        if call.body.count > maxRequestBytes + 5 {
          call.tooLarge = true
          call.body.clear()
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
  monitorEnter(cs)
  defer {
    monitorExit(cs)
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
  monitorEnter(server)
  server.nextConnId = server.nextConnId + 1
  val cs = ConnState(id = server.nextConnId, conn = conn, h2 = h2, calls = newList(), active = 0, open = true)
  server.conns.add(cs)
  monitorExit(server)
  hostSetIoTimeout(conn, server.maxIdleMs)
  monitorEnter(cs)
  writeLocked(cs, H2.serverInitialFrame(h2))
  monitorExit(cs)
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
            val _ = taskRun({ -> runCall(server, cs, call) })
          }
        }
      }
    }
  }
  monitorEnter(cs)
  cs.open = false
  for c in cs.calls {
    c.cancelled = true
  }
  monitorExit(cs)
  hostClose(conn)
  forgetConnection(server, cs)
}

/// A finished connection must not stay reachable from the server: it holds the
/// HTTP/2 state, the call list and the socket wrapper.
func forgetConnection(server: in ServerState, cs: in ConnState): Unit {
  monitorEnter(server)
  defer {
    monitorExit(server)
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

func acceptLoop(server: in ServerState): Unit {
  var running = true
  while running {
    match hostAccept(server.listener) {
      case Std.Core.Ok(conn) -> {
        if server.stopping {
          hostClose(conn)
        } else {
          val _ = taskRun({ -> serveConnection(server, conn) })
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
): ServerState {
  if reflectionEnabled {
    panic("gRPC server reflection is not supported: set GrpcServer.reflectionEnabled to false")
  }
  match hostListen(host, port) {
    case Std.Core.Err(e) -> panic(
      "gRPC server could not start on " + host + ":" + port.toString() + ": " +
        TcpError.message(e)
    )
    case Std.Core.Ok(listener) -> {
      ServerState(
        listener = listener,
        registry = registry,
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

/// Serve on the calling thread until the process exits.
pub func serve(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): Unit {
  acceptLoop(openServer(host, port, reflectionEnabled, maxConnectionIdleMs, registry))
}

pub func startServer(
  host: in String,
  port: in Int,
  reflectionEnabled: in Bool,
  maxConnectionIdleMs: in Int,
  registry: in ServiceRegistry,
): GrpcServerHandle {
  val server = openServer(host, port, reflectionEnabled, maxConnectionIdleMs, registry)
  val _ = taskRun({ -> acceptLoop(server) })
  monitorEnter(serverTable)
  serverTable.items.add(server)
  val id = serverTable.items.count
  monitorExit(serverTable)
  Types.wrapServerHandle(id)
}

func lookup(handle: in GrpcServerHandle): Option[ServerState] {
  monitorEnter(serverTable)
  defer {
    monitorExit(serverTable)
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
  monitorEnter(server)
  defer {
    monitorExit(server)
  }
  server.inflight
}

/// The connections the server currently tracks (open ones; a closed
/// connection is forgotten). `0` for an unknown handle.
pub func trackedConnections(handle: in GrpcServerHandle): Int {
  match lookup(handle) {
    case Some(server) -> {
      monitorEnter(server)
      defer {
        monitorExit(server)
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
      monitorEnter(server)
      val first = not server.stopping
      server.stopping = true
      monitorExit(server)
      if first {
        hostStopListener(server.listener)
        val giveUpAt = Std.Time.nowEpochMillis() + drainTimeoutMs.toLong()
        while inflightCalls(server) > 0 and Std.Time.nowEpochMillis() < giveUpAt {
          sleepMillis(10)
        }
        monitorEnter(server)
        val conns = server.conns.toArray()
        monitorExit(server)
        for cs in conns {
          monitorEnter(cs)
          cs.open = false
          monitorExit(cs)
          hostClose(cs.conn)
        }
        monitorEnter(server)
        server.conns.clear()
        server.stopped = true
        monitorExit(server)
      }
    }
  }
}
