//! std/_kernel_jvm/tcp_host.l - JVM TCP + server-side TLS transport kernel.
//!
//! The JVM twin of `_kernel/tcp_host.l`: the same public `host*` surface
//! (`hostListen`/`hostLocalPort`/`hostConnect`/`hostAccept`/`hostAcceptTls`/
//! `hostPrepareServerTls`/`hostUpgradeServerTls[Prepared]`/`hostSetIoTimeout`/
//! `hostAlpn`/`hostRead`/`hostWrite`/`hostRemoteAddress`/`hostClose`) over
//! `java.net.Socket`, `java.net.ServerSocket` and `javax.net.ssl.SSLSocket`
//! through the JVM auto-FFI. Before this file existed the .NET kernel was
//! compiled for the JVM and failed with `J002` (#9042).
//!
//! Semantics shared with the .NET kernel, so a program written against
//! `Std.TcpHost` runs unchanged on both targets:
//!
//!   - every operation returns `Result[_, TcpError]`; an SDK exception never
//!     escapes the public API;
//!   - `hostRead` returns an empty slice at end of stream;
//!   - `hostSetIoTimeout` bounds each blocking read and write by `timeoutMs`
//!     of inactivity (`0` = none) and a timeout is `Err(TransportFailed(...))`;
//!   - `hostConnect` takes a connect timeout (`0` = the operating system's);
//!   - `hostStopListener` closes the listening socket, which ends a
//!     concurrent `hostAccept` with `Err(AcceptFailed(...))`;
//!   - server TLS: the certificate/key `Identity`, the minimum protocol
//!     version, ALPN (`h2` then `http/1.1`) and mutual TLS (`requireClientCert`
//!     and `clientCa`; a `clientCa` without `requireClientCert` asks for a
//!     client certificate and verifies one that is sent).
//!
//! Representation notes:
//!
//!   - A read blocks for the first byte (`InputStream.read()`), then takes
//!     what `available()` reports without blocking further. This is how a
//!     blocking stream is given the "return what has arrived" contract of
//!     `NetworkStream.Read`; `InputStream.read(byte[], int, int)` cannot be
//!     used because a Lyric `slice[Byte]` argument is passed as a copy there,
//!     so the bytes read would never reach the caller.
//!   - A write has no `SO_SNDTIMEO` equivalent on a blocking `java.net.Socket`.
//!     When an I/O timeout is set the write runs on a virtual thread that is
//!     abandoned, and the socket closed, after `timeoutMs` ms without
//!     progress (the same watchdog `Net.Tcp.Kernel` uses in `lyric-ecosystem`).
//!   - The server `SSLContext` is built by `Std.HttpServer`
//!     (`serverSslContextFromConfig[Mtls]`), the one place that owns the
//!     `KeyManagerFactory`/`KeyStore` reflection bridge and the TLS 1.2 floor
//!     check, so there is exactly one server-context construction on this
//!     target. Array-typed JDK parameters (`SSLParameters.setProtocols`,
//!     `setApplicationProtocols`) are filled through `java.lang.reflect`,
//!     because a Lyric `slice[T]` of references erases to `Object[]` at the
//!     call site.
@axiom("java.net.Socket, ServerSocket and javax.net.ssl.SSLSocket operations conform to their documented JVM contracts")
@io
package Std.TcpHost

import Std.Core
import Std.Tls as Tls
import Std.HttpServer as HttpSrv

extern type JSocket = "java.net.Socket"

extern type JServerSocket = "java.net.ServerSocket"

extern type JInetSocketAddress = "java.net.InetSocketAddress"

extern type JInetAddress = "java.net.InetAddress"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JBAOS = "java.io.ByteArrayOutputStream"

extern type JRunnable = "java.lang.Runnable"

extern type JThread = "java.lang.Thread"

extern type JAtomicLong = "java.util.concurrent.atomic.AtomicLong"

extern type JObject = "java.lang.Object"

extern type JArrayList = "java.util.ArrayList"

extern type JClass = "java.lang.Class"

extern type JMethod = "java.lang.reflect.Method"

extern type JReflectArray = "java.lang.reflect.Array"

extern type JSSLContext = "javax.net.ssl.SSLContext"

extern type JSSLParameters = "javax.net.ssl.SSLParameters"

extern type JSSLSocketFactory = "javax.net.ssl.SSLSocketFactory"

extern type JSSLSocket = "javax.net.ssl.SSLSocket"

/// Why a transport operation failed. The message is the platform's own
/// description (the exception message), so it is for humans and logs; the
/// case is what a caller branches on.
@experimental
pub union TcpError {
  case BindFailed(message: String)
  case AcceptFailed(message: String)
  case TlsHandshakeFailed(message: String)
  case TransportFailed(message: String)
  case TlsConfigInvalid(message: String)
}

/// A one-line human description of `e`.
@pure
@experimental
pub func TcpError.message(e: in TcpError): String {
  match e {
    case BindFailed(m) -> "bind failed: " + m
    case AcceptFailed(m) -> "accept failed: " + m
    case TlsHandshakeFailed(m) -> "TLS handshake failed: " + m
    case TransportFailed(m) -> "I/O error: " + m
    case TlsConfigInvalid(m) -> "TLS configuration invalid: " + m
  }
}

/// A bound, listening TCP socket.
@experimental
pub opaque type Listener {
  server: JServerSocket
}

/// One connection. `writeTimeoutMs` is the inactivity limit of a write
/// (`0` = none; a plain `java.net.Socket` has no send timeout of its own, see
/// the module header), shared by the plain and the TLS-layered `Conn` of one
/// socket; `alpn` is the negotiated ALPN protocol (`""` for a plain
/// connection, or a TLS connection where the peer offered none).
@experimental
pub opaque type Conn {
  socket: JSocket
  input: JInputStream
  output: JOutputStream
  alpn: String
  writeTimeoutMs: JAtomicLong
}

/// A server TLS configuration prepared once and reused for every accepted
/// connection (`hostPrepareServerTls`).
@experimental
pub opaque type ServerTls {
  ctx: JSSLContext
  tls13Only: Bool
  needClientAuth: Bool
  wantClientAuth: Bool
}

val backlog: Int = 128

func wrapSocket(socket: in JSocket, alpn: in String, writeTimeoutMs: in JAtomicLong): Conn {
  socket.setTcpNoDelay(true)
  val input: JInputStream = socket.getInputStream()
  val output: JOutputStream = socket.getOutputStream()
  Conn(socket = socket, input = input, output = output, alpn = alpn, writeTimeoutMs = writeTimeoutMs)
}

func closeQuietly(socket: in JSocket): Unit {
  try {
    socket.close()
  } catch Bug as _ {
    ()
  }
}

func isTimeout(typeName: in String): Bool {
  typeName == "SocketTimeoutException" or typeName == "java.net.SocketTimeoutException"
}

func failureText(typeName: in String, message: in String): String {
  if message.length > 0 {
    message
  } else {
    typeName
  }
}

/// Bind and listen on `host`:`port` (`port` 0 = an ephemeral port, read back
/// with `hostLocalPort`). `host` is an address literal or a name the platform
/// resolves.
@experimental
pub func hostListen(host: in String, port: in Int): Result[Listener, TcpError] {
  try {
    val address: JInetAddress = JInetAddress.getByName(host)
    val server: JServerSocket = JServerSocket.new(port, backlog, address)
    Ok(value = Listener(server = server))
  } catch Bug as b {
    Err(error = BindFailed(message = failureText(b.typeName, b.message)))
  }
}

/// The port `l` is actually bound to; `0` if it cannot be read.
@experimental
pub func hostLocalPort(l: in Listener): Int {
  try {
    l.server.getLocalPort()
  } catch Bug as _ {
    0
  }
}

/// Dial a plain (non-TLS) TCP connection to `host`:`port`. `host` may be an
/// IP literal or a DNS name. `connectTimeoutMs` bounds the connect, name
/// resolution included where the platform allows (`0` = the operating
/// system's own limit). A connect failure (refused, unreachable, unresolved,
/// timed out) is `Err(TransportFailed(...))`.
@experimental
pub func hostConnect(host: in String, port: in Int, connectTimeoutMs: in Int): Result[Conn, TcpError]
  requires: connectTimeoutMs >= 0
{
  val socket: JSocket = JSocket.new()
  try {
    val address: JInetSocketAddress = JInetSocketAddress.new(host, port)
    socket.connect(address, connectTimeoutMs)
    Ok(value = wrapSocket(socket, "", JAtomicLong.new()))
  } catch Bug as b {
    closeQuietly(socket)
    if isTimeout(b.typeName) {
      Err(error = TransportFailed(message = "connect timed out after " + connectTimeoutMs.toString() + " ms"))
    } else {
      Err(error = TransportFailed(message = failureText(b.typeName, b.message)))
    }
  }
}

/// Stop listening: closes the listening socket, which ends a concurrent
/// `hostAccept` on another thread with `Err(AcceptFailed(...))`. Swallows a
/// double stop.
@experimental
pub func hostStopListener(l: in Listener): Unit {
  try {
    l.server.close()
  } catch Bug as _ {
    ()
  }
}

/// Block until a client connects and return the plain connection.
@experimental
pub func hostAccept(l: in Listener): Result[Conn, TcpError] {
  try {
    val socket: JSocket = l.server.accept()
    Ok(value = wrapSocket(socket, "", JAtomicLong.new()))
  } catch Bug as b {
    Err(error = AcceptFailed(message = failureText(b.typeName, b.message)))
  }
}

func validateServerConfig(cfg: in Tls.TlsServerConfig): Option[TcpError] {
  if cfg.requireClientCert {
    match cfg.clientCa {
      case None -> Some(
        value = TlsConfigInvalid(
          message = "requireClientCert is set but no clientCa is configured; mutual TLS must pin trust to a client CA " +
            "(refusing to fall back to the system trust store, which would accept any publicly-trusted client certificate)"
        )
      )
      case Some(_) -> None
    }
  } else {
    None
  }
}

func buildContext(cfg: in Tls.TlsServerConfig): JSSLContext {
  match cfg.clientCa {
    case Some(ca) -> {
      val sc = HttpSrv.serverSslContextFromConfigMtls(cfg.identity, cfg.minVersion, ca)
      val ctx: JSSLContext = HttpSrv.ServerSslContext.rawContext(sc)
      ctx
    }
    case None -> {
      val sc = HttpSrv.serverSslContextFromConfig(cfg.identity, cfg.minVersion)
      val ctx: JSSLContext = HttpSrv.ServerSslContext.rawContext(sc)
      ctx
    }
  }
}

func isTls13Only(v: in Tls.TlsVersion): Bool {
  match v {
    case Tls13 -> true
    case Tls12 -> false
  }
}

func hasClientCa(cfg: in Tls.TlsServerConfig): Bool {
  match cfg.clientCa {
    case Some(_) -> true
    case None -> false
  }
}

/// Prepare `cfg` once for reuse across connections: builds the server
/// `SSLContext` (certificate, private key, minimum version, client-CA trust).
/// A configuration the platform cannot load is `Err(TlsConfigInvalid(...))`.
@experimental
pub func hostPrepareServerTls(cfg: in Tls.TlsServerConfig): Result[ServerTls, TcpError] {
  match validateServerConfig(cfg) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }
  try {
    val ctx = buildContext(cfg)
    Ok(
      value = ServerTls(
        ctx = ctx,
        tls13Only = isTls13Only(cfg.minVersion),
        needClientAuth = cfg.requireClientCert,
        wantClientAuth = hasClientCa(cfg) and not cfg.requireClientCert
      )
    )
  } catch Bug as b {
    Err(error = TlsConfigInvalid(message = failureText(b.typeName, b.message)))
  }
}

/// Release a prepared configuration. A prepared configuration holds only
/// garbage-collected state on this target, so this is a no-op kept for the
/// twin kernels' shared surface.
@experimental
pub func hostReleaseServerTls(t: in ServerTls): Unit {
  ()
}

/// Accept one connection and terminate TLS on it, as a server.
@experimental
pub func hostAcceptTls(l: in Listener, cfg: in Tls.TlsServerConfig): Result[Conn, TcpError] {
  match validateServerConfig(cfg) {
    case Some(e) -> Err(error = e)
    case None -> match hostAccept(l) {
      case Err(e) -> Err(error = e)
      case Ok(plain) -> hostUpgradeServerTls(plain, cfg)
    }
  }
}

func stringArray(first: in String, second: in String): JObject {
  val stringClass: JClass = JClass.forName("java.lang.String")
  val count = if second.length > 0 { 2 } else { 1 }
  val array: JObject = JReflectArray.newInstance(stringClass, count)
  JReflectArray.set(array, 0, first)
  if second.length > 0 {
    JReflectArray.set(array, 1, second)
  }
  array
}

func findMethod(className: in String, name: in String, arity: in Int): JMethod {
  val cls: JClass = JClass.forName(className)
  val methods: slice[JMethod] = cls.getMethods()
  var i = 0
  while i < methods.length {
    val m = methods[i]
    if m.getName() == name and m.getParameterCount() == arity {
      return m
    }
    i = i + 1
  }
  panic("Std.TcpHost: no method " + className + "." + name + " with " + arity.toString() + " parameters")
}

func invokeWithArray(parameters: in JSSLParameters, name: in String, array: in JObject): Unit {
  val arguments: JArrayList = JArrayList.new()
  arguments.add(array)
  val _ = findMethod("javax.net.ssl.SSLParameters", name, 1).invoke(parameters, arguments.toArray())
}

func layerServerTls(ctx: in JSSLContext, plain: in JSocket): JSSLSocket {
  val factory: JSSLSocketFactory = ctx.getSocketFactory()
  val layered: JSocket = factory.createSocket(plain, plain.getInetAddress().getHostAddress(), plain.getPort(), true)
  val sslClass: JClass = JClass.forName("javax.net.ssl.SSLSocket")
  val ssl: JSSLSocket = sslClass.cast(layered)
  ssl
}

func configureServerSocket(ssl: in JSSLSocket, tls: in ServerTls): Unit {
  ssl.setUseClientMode(false)
  if tls.needClientAuth {
    ssl.setNeedClientAuth(true)
  } else if tls.wantClientAuth {
    ssl.setWantClientAuth(true)
  }
  val parameters: JSSLParameters = ssl.getSSLParameters()
  if tls.tls13Only {
    invokeWithArray(parameters, "setProtocols", stringArray("TLSv1.3", ""))
  }
  invokeWithArray(parameters, "setApplicationProtocols", stringArray("h2", "http/1.1"))
  ssl.setSSLParameters(parameters)
}

/// Terminate TLS on an already-accepted plain connection, as a server (the
/// accept/upgrade split so a driver can run the handshake off its accept
/// loop). `handshakeTimeoutMs` (`0` = no limit) bounds each blocking socket
/// operation of the handshake, so a peer that connects and never finishes its
/// ClientHello fails instead of holding the connection open forever. On `Err`
/// the plain `conn` is left for the caller to `hostClose` (closing again is
/// harmless).
@experimental
pub func hostUpgradeServerTlsPrepared(
  conn: in Conn, tls: in ServerTls, handshakeTimeoutMs: in Int
): Result[Conn, TcpError]
  requires: handshakeTimeoutMs >= 0
{
  try {
    val ssl = layerServerTls(tls.ctx, conn.socket)
    val settled = conn.socket.getSoTimeout()
    try {
      configureServerSocket(ssl, tls)
      if handshakeTimeoutMs > 0 {
        ssl.setSoTimeout(handshakeTimeoutMs)
      }
      ssl.startHandshake()
      ssl.setSoTimeout(settled)
      val layered: JSocket = ssl
      val negotiated: String = ssl.getApplicationProtocol()
      Ok(value = wrapSocket(layered, negotiated, conn.writeTimeoutMs))
    } catch Bug as b {
      closeQuietly(ssl)
      Err(error = TlsHandshakeFailed(message = failureText(b.typeName, b.message)))
    }
  } catch Bug as b {
    closeQuietly(conn.socket)
    Err(error = TlsHandshakeFailed(message = failureText(b.typeName, b.message)))
  }
}

/// Terminate TLS on an already-accepted plain connection, as a server, from
/// `cfg` directly. The plain connection is closed on every failure.
@experimental
pub func hostUpgradeServerTls(conn: in Conn, cfg: in Tls.TlsServerConfig): Result[Conn, TcpError] {
  match hostPrepareServerTls(cfg) {
    case Err(e) -> {
      closeQuietly(conn.socket)
      Err(error = e)
    }
    case Ok(tls) -> match hostUpgradeServerTlsPrepared(conn, tls, 0) {
      case Ok(upgraded) -> Ok(value = upgraded)
      case Err(e) -> {
        hostClose(conn)
        Err(error = e)
      }
    }
  }
}

/// Bound every subsequent blocking read and write on `conn` to `timeoutMs`
/// milliseconds of inactivity (`0` = no limit). A read or write that times
/// out returns `Err(TransportFailed(...))`. Best-effort: a socket that is
/// already closed ignores the call (its next read or write fails anyway).
@experimental
pub func hostSetIoTimeout(conn: in Conn, timeoutMs: in Int): Unit
  requires: timeoutMs >= 0
{
  try {
    conn.socket.setSoTimeout(timeoutMs)
    conn.writeTimeoutMs.set(timeoutMs.toLong())
  } catch Bug as _ {
    ()
  }
}

/// The negotiated ALPN protocol for this connection (`"http/1.1"`, `"h2"`,
/// or `""` when none was negotiated / the connection is plain).
@experimental
pub func hostAlpn(c: in Conn): String {
  c.alpn
}

func baosWriteByte(acc: in JBAOS, b: in Int): Unit {
  acc.write(b)
}

func baosWriteBytes(acc: in JBAOS, bytes: in slice[Byte]): Unit {
  acc.write(bytes)
}

func readChunk(c: in Conn, maxBytes: in Int): slice[Byte] {
  val acc: JBAOS = JBAOS.new()
  val first = c.input.read()
  if first < 0 {
    return acc.toByteArray()
  }
  baosWriteByte(acc, first)
  val avail = c.input.available()
  if avail > 0 and maxBytes > 1 {
    val want = if avail < maxBytes - 1 { avail } else { maxBytes - 1 }
    baosWriteBytes(acc, c.input.readNBytes(want))
  }
  acc.toByteArray()
}

/// Read up to `maxBytes` bytes from the connection, blocking until at least
/// one byte arrives. Returns the bytes actually read; an empty slice means
/// the peer closed its half of the connection (EOF). A socket error or an I/O
/// timeout is `Err(TransportFailed(...))`. Reads on one connection must not
/// run concurrently.
@experimental
pub func hostRead(c: in Conn, maxBytes: in Int): Result[slice[Byte], TcpError]
  requires: maxBytes > 0
{
  try {
    Ok(value = readChunk(c, maxBytes))
  } catch Bug as b {
    if isTimeout(b.typeName) {
      Err(error = TransportFailed(message = "read timed out"))
    } else {
      Err(error = TransportFailed(message = failureText(b.typeName, b.message)))
    }
  }
}

func writeAll(output: in JOutputStream, bytes: in slice[Byte]): Unit {
  output.write(bytes)
  output.flush()
}

val writeChunkBytes: Int = 65536

ref record WriteJob {
  output: JOutputStream
  bytes: slice[Byte]
  progress: JAtomicLong
  var failure: String
}

func writeChunks(job: in WriteJob): Unit {
  val total = job.bytes.length
  if total <= writeChunkBytes {
    job.output.write(job.bytes)
  } else {
    var offset = 0
    while offset < total {
      val stop = if total - offset < writeChunkBytes { total } else { offset + writeChunkBytes }
      job.output.write(job.bytes.slice(offset, stop))
      val _ = job.progress.incrementAndGet()
      offset = stop
    }
  }
  job.output.flush()
}

impl JRunnable for WriteJob {
  func run(): Unit {
    try {
      writeChunks(self)
    } catch Bug as b {
      self.failure = failureText(b.typeName, b.message)
    }
  }
}

func writerFinished(writer: in JThread, job: in WriteJob, timeoutMs: in Int): Bool {
  var seen = 0i64
  while true {
    writer.join(timeoutMs.toLong())
    if not writer.isAlive() {
      return true
    }
    val now = job.progress.get()
    if now == seen {
      return false
    }
    seen = now
  }
  true
}

func writeWithin(c: in Conn, bytes: in slice[Byte], timeoutMs: in Int): Result[Unit, TcpError] {
  val job = WriteJob(output = c.output, bytes = bytes, progress = JAtomicLong.new(), failure = "")
  val writer: JThread = JThread.startVirtualThread(job)
  if not writerFinished(writer, job, timeoutMs) {
    closeQuietly(c.socket)
    return Err(
      error = TransportFailed(
        message = "write timed out: the peer accepted no data for " + timeoutMs.toString() + " ms"
      )
    )
  }
  if job.failure.length > 0 {
    Err(error = TransportFailed(message = job.failure))
  } else {
    Ok(value = ())
  }
}

/// Write all of `bytes` to the connection and flush. A broken pipe, a reset
/// connection or an I/O timeout is `Err(TransportFailed(...))` rather than an
/// uncaught exception.
@experimental
pub func hostWrite(c: in Conn, bytes: in slice[Byte]): Result[Unit, TcpError] {
  try {
    val limit = c.writeTimeoutMs.get().toInt()
    if limit == 0 {
      writeAll(c.output, bytes)
      Ok(value = ())
    } else {
      writeWithin(c, bytes, limit)
    }
  } catch Bug as b {
    Err(error = TransportFailed(message = failureText(b.typeName, b.message)))
  }
}

/// The connection's remote endpoint as a string (e.g. `"127.0.0.1:54321"`),
/// or `""` if it cannot be determined. A best-effort diagnostic value, never
/// load-bearing for protocol correctness.
@experimental
pub func hostRemoteAddress(c: in Conn): String {
  try {
    val address: String = c.socket.getInetAddress().getHostAddress()
    val port: Int = c.socket.getPort()
    if address.contains(":") {
      "[" + address + "]:" + port.toString()
    } else {
      address + ":" + port.toString()
    }
  } catch Bug as _ {
    ""
  }
}

/// Close the connection, releasing the socket (and, for a TLS connection, the
/// `SSLSocket` over it). Swallows a double close.
@experimental
pub func hostClose(c: in Conn): Unit {
  closeQuietly(c.socket)
}
