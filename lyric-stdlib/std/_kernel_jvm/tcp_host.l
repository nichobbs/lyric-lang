//! std/_kernel_jvm/tcp_host.l - JVM TCP + server-side TLS transport kernel.
//!
//! The JVM twin of `_kernel/tcp_host.l`: the same public `host*` surface
//! (`hostListen`/`hostLocalPort`/`hostConnect`/`hostAccept`/`hostAcceptTls`/
//! `hostPrepareServerTls`/`hostUpgradeServerTls[Prepared]`/`hostSetIoTimeout`/
//! `hostAlpn`/`hostRead`/`hostWrite`/`hostShutdown`/`hostRemoteAddress`/
//! `hostClose`) over `java.net.Socket`, `java.net.ServerSocket` and
//! `javax.net.ssl.SSLSocket` through the JVM auto-FFI. Before this file
//! existed the .NET kernel was compiled for the JVM and failed with `J002`
//! (#9042). D621 (docs/73 slice S1) made it fit to carry a server.
//!
//! Semantics shared with the .NET and native kernels, so a program written
//! against `Std.TcpHost` runs unchanged on every target:
//!
//!   - every operation returns `Result[_, TcpError]`; an SDK exception never
//!     escapes the public API;
//!   - `hostRead` blocks for the first byte, returns what has arrived up to
//!     `maxBytes`, and returns an empty slice at end of stream;
//!   - `hostSetIoTimeout` bounds each blocking read and write by `timeoutMs`
//!     of inactivity (`0` = none) and a timeout is `Err(TransportFailed(...))`;
//!   - `hostShutdown` ends a read or write blocked on the connection from
//!     another thread without releasing it (see its doc comment);
//!   - `hostConnect` takes a connect timeout (`0` = the operating system's);
//!   - `hostStopListener` closes the listening socket, which ends a
//!     concurrent `hostAccept` with `Err(AcceptFailed(...))`;
//!   - server TLS: the certificate/key `Identity`, the minimum protocol
//!     version, ALPN (`h2` then `http/1.1`) and mutual TLS (`requireClientCert`
//!     and `clientCa`; a `clientCa` without `requireClientCert` asks for a
//!     client certificate and verifies one that is sent).
//!
//! ## Reads
//!
//! A Lyric `slice[Byte]` is an `Object[]` of boxed bytes on this target, and
//! passing one to a JDK `byte[]` parameter materialises a COPY, so
//! `InputStream.read(byte[], int, int)` can only fill a buffer the Lyric side
//! never holds as a `slice`. Each connection therefore owns one reusable
//! `ByteBuffer` (16 KiB, the .NET kernel's `readBufferSize`) whose backing
//! array is fetched as an extern argument in the same expression that
//! consumes it (`stream.read(buffer.array(), 0, n)`): the compiler hands the
//! raw `byte[]` through, `read` fills it in place, and only the `n` bytes that
//! arrived leave as a fresh slice (`Arrays.copyOfRange`, then the one boxing
//! pass the slice representation requires). That is the whole per-call cost:
//! no `ByteArrayOutputStream`, no `available()`/`readNBytes()` follow-up
//! calls, no per-call buffer. The buffer is never bound to a Lyric name
//! (T0157, #8730), which would turn it into a copy. Reads on one connection
//! must not run concurrently (they share the buffer).
//!
//! One `InputStream.read(buf, 0, n)` already has the contract of `hostRead`:
//! it blocks until at least one byte is available and returns what is
//! available up to `n`, so no buffered stream and no `available()` probe are
//! needed. That also makes a TLS (`SSLSocket`) connection correct without
//! relying on `SSLSocket.available()`, which reports only bytes of the
//! current decrypted record and is zero between records: the SSL stream's own
//! `read(buf, 0, n)` decrypts the next record when none is buffered and
//! returns its application data.
//!
//! ## Writes and the write timeout
//!
//! A write has no `SO_SNDTIMEO` equivalent on a blocking `java.net.Socket`.
//! When an I/O timeout is set, ONE shared watchdog (a single virtual thread
//! started on first use, sweeping every 50 ms) enforces it: `hostWrite` stamps
//! the connection's guard with a deadline before each write and clears it
//! after, on the caller's own thread, so a write costs two atomic stores and no
//! thread. The watchdog closes the underlying socket of a guard whose armed
//! deadline has passed, which makes the blocked `write` throw; `hostWrite`
//! then reports `TransportFailed("write timed out: ...")`. Cost model: the
//! deadline is detected within one sweep (50 ms) after it expires, a connection
//! with a timeout set costs one atomic read per sweep, and a connection whose
//! socket is closed leaves the registry at the next sweep.
//!
//! Progress semantics are explicit and chunk-granular. A write of at most
//! 64 KiB is one `OutputStream.write`, which gives no visibility into partial
//! progress: it must complete as a whole within `timeoutMs` or the connection is
//! closed, even if the peer was still accepting data slowly. A larger write is
//! sent in 64 KiB chunks and every completed chunk re-arms a fresh `timeoutMs`
//! window, so a peer that keeps draining is never cut off, while a peer that
//! accepts nothing for `timeoutMs` ends the write at the limit. A timed-out
//! write closes the connection (some of the bytes may have been sent; the
//! caller cannot know how many). Writes on one connection must not run
//! concurrently (they share the guard).
//!
//! ## Shutdown and close on TLS
//!
//! `SSLSocket` does not support half-close (`shutdownInput`/`shutdownOutput`
//! throw `UnsupportedOperationException`), and closing it from another thread
//! while a write holds the TLS output lock can itself block. `hostShutdown`
//! therefore acts on the underlying plain `Socket` (kept in `Conn.raw`) for
//! both connection kinds, which is what native's raw `shutdown(2)` and
//! dotnet's `Socket.Shutdown` do; the watchdog likewise closes `raw`.
//!
//! The server `SSLContext` comes from `Std.TlsServerContext`
//! (`_kernel_jvm/tls_server_context.l`), shared with `Std.HttpServer`, so this
//! kernel no longer imports `Std.HttpServer`. Array-typed JDK parameters
//! (`SSLParameters.setProtocols`, `setApplicationProtocols`) are filled
//! through `java.lang.reflect`, because a Lyric `slice[T]` of references erases
//! to `Object[]` at the call site.
@axiom("java.net.Socket, ServerSocket and javax.net.ssl.SSLSocket operations conform to their documented JVM contracts")
@io
package Std.TcpHost

import Std.Core
import Std.Tls as Tls
import Std.TlsServerContext as Ctx

extern type JSocket = "java.net.Socket"

extern type JServerSocket = "java.net.ServerSocket"

extern type JInetSocketAddress = "java.net.InetSocketAddress"

extern type JInetAddress = "java.net.InetAddress"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JByteBuffer = "java.nio.ByteBuffer"

extern type JArrays = "java.util.Arrays"

extern type JRunnable = "java.lang.Runnable"

extern type JThread = "java.lang.Thread"

extern type JSystem = "java.lang.System"

extern type JAtomicLong = "java.util.concurrent.atomic.AtomicLong"

extern type JAtomicBoolean = "java.util.concurrent.atomic.AtomicBoolean"

extern type JConcurrentHashMap = "java.util.concurrent.ConcurrentHashMap"

extern type JSet = "java.util.Set"

extern type JIterator = "java.util.Iterator"

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

// The write watchdog's per-connection record (module header). `state` is 0
// (no write in flight), 1 (a write is armed with `deadlineNanos`) or 2 (the
// watchdog fired: the write timed out and `raw` was closed); only a
// compare-and-set from 1 decides between "the write finished" and "the
// watchdog fired", so a write that completes is never closed after the fact.
// The registry holds one guard per connection with an I/O timeout, shared by
// the plain and the TLS-layered `Conn` of one socket.
ref record WriteGuard {
  raw: JSocket
  state: JAtomicLong
  deadlineNanos: JAtomicLong
}

/// One connection. `socket` is the plain socket or the `SSLSocket` over it;
/// `raw` is always the underlying plain socket (the one the watchdog and
/// `hostShutdown` act on, module header); `readBuf` is the per-connection read
/// buffer; `timeoutMs` is the I/O timeout (`0` = none) shared by the plain
/// and the TLS-layered `Conn` of one socket; `alpn` is the negotiated ALPN
/// protocol (`""` for a plain connection, or a TLS connection where the peer
/// offered none).
@experimental
pub opaque type Conn {
  socket: JSocket
  raw: JSocket
  input: JInputStream
  output: JOutputStream
  readBuf: JByteBuffer
  alpn: String
  timeoutMs: JAtomicLong
  guard: WriteGuard
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

// The listen queue length passed to `ServerSocket`: native passes 128 too;
// dotnet's `TcpListener.Start()` asks for SOMAXCONN, which the operating
// system clamps to its own limit (often larger), so a connection storm can
// queue deeper on dotnet (D621).
val backlog: Int = 128

val readBufferSize: Int = 16384

val writeChunkBytes: Int = 65536

val watchdogTickMs: Int = 50

// Registry of guards with an I/O timeout, swept by the one watchdog thread.
val guards: JSet = JConcurrentHashMap.newKeySet()

val watchdogStarted: JAtomicBoolean = JAtomicBoolean.new()

func closeQuietly(socket: in JSocket): Unit {
  try {
    socket.close()
  } catch Bug as _ {
    ()
  }
}

// Called by the watchdog sweep for every guard, on its own thread.
impl JRunnable for WriteGuard {
  func run(): Unit {
    try {
      if self.raw.isClosed() {
        val _ = guards.remove(self)
      } else if self.state.get() == 1i64 {
        val expired = JSystem.nanoTime() - self.deadlineNanos.get() >= 0i64
        if expired and self.state.compareAndSet(1i64, 2i64) {
          closeQuietly(self.raw)
        }
      }
    } catch Bug as _ {
      ()
    }
  }
}

ref record Watchdog {
  tickMs: Int
}

func sweep(): Unit {
  val it: JIterator = guards.iterator()
  while it.hasNext() {
    val g: JRunnable = it.next()
    g.run()
  }
}

impl JRunnable for Watchdog {
  func run(): Unit {
    while true {
      try {
        JThread.sleep(self.tickMs.toLong())
        sweep()
      } catch Bug as _ {
        ()
      }
    }
  }
}

func ensureWatchdog(): Unit {
  if watchdogStarted.compareAndSet(false, true) {
    val _ = JThread.startVirtualThread(Watchdog(tickMs = watchdogTickMs))
  }
}

func newGuard(raw: in JSocket): WriteGuard {
  WriteGuard(raw = raw, state = JAtomicLong.new(), deadlineNanos = JAtomicLong.new())
}

func wrapSocket(
  socket: in JSocket, raw: in JSocket, alpn: in String, timeoutMs: in JAtomicLong, guard: in WriteGuard
): Conn {
  try {
    socket.setTcpNoDelay(true)
    val input: JInputStream = socket.getInputStream()
    val output: JOutputStream = socket.getOutputStream()
    Conn(
      socket = socket,
      raw = raw,
      input = input,
      output = output,
      readBuf = JByteBuffer.allocate(readBufferSize),
      alpn = alpn,
      timeoutMs = timeoutMs,
      guard = guard
    )
  } catch Bug as b {
    closeQuietly(socket)
    panic(failureText(b.typeName, b.message))
  }
}

func wrapPlain(socket: in JSocket): Conn {
  wrapSocket(socket, socket, "", JAtomicLong.new(), newGuard(socket))
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
  try {
    val socket: JSocket = JSocket.new()
    try {
      val address: JInetSocketAddress = JInetSocketAddress.new(host, port)
      socket.connect(address, connectTimeoutMs)
      Ok(value = wrapPlain(socket))
    } catch Bug as b {
      closeQuietly(socket)
      if isTimeout(b.typeName) {
        Err(error = TransportFailed(message = "connect timed out after " + connectTimeoutMs.toString() + " ms"))
      } else {
        Err(error = TransportFailed(message = failureText(b.typeName, b.message)))
      }
    }
  } catch Bug as b {
    Err(error = TransportFailed(message = failureText(b.typeName, b.message)))
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
    Ok(value = wrapPlain(socket))
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
      val sc = Ctx.serverSslContextFromConfigMtls(cfg.identity, cfg.minVersion, ca)
      val ctx: JSSLContext = Ctx.ServerSslContext.rawContext(sc)
      ctx
    }
    case None -> {
      val sc = Ctx.serverSslContextFromConfig(cfg.identity, cfg.minVersion)
      val ctx: JSSLContext = Ctx.ServerSslContext.rawContext(sc)
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
      Ok(value = wrapSocket(layered, conn.raw, negotiated, conn.timeoutMs, conn.guard))
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
/// A read is bounded by `SO_TIMEOUT`; a write by the shared watchdog with the
/// chunk-granular progress rule in the module header.
@experimental
pub func hostSetIoTimeout(conn: in Conn, timeoutMs: in Int): Unit
  requires: timeoutMs >= 0
{
  try {
    conn.socket.setSoTimeout(timeoutMs)
    conn.timeoutMs.set(timeoutMs.toLong())
    if timeoutMs > 0 {
      val _ = guards.add(conn.guard)
      ensureWatchdog()
    } else {
      val _ = guards.remove(conn.guard)
    }
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

func readChunk(c: in Conn, maxBytes: in Int): slice[Byte] {
  val want = if maxBytes < readBufferSize { maxBytes } else { readBufferSize }
  val n: Int = c.input.read(c.readBuf.array(), 0, want)
  if n <= 0 {
    return []
  }
  JArrays.copyOfRange(c.readBuf.array(), 0, n)
}

/// Read up to `maxBytes` bytes from the connection, blocking until at least
/// one byte arrives. Returns the bytes actually read (at most 16 KiB per call);
/// an empty slice means the peer closed its half of the connection (EOF). A
/// socket error or an I/O timeout is `Err(TransportFailed(...))`. Reads on one
/// connection must not run concurrently (they share the connection's read
/// buffer).
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

func armWrite(g: in WriteGuard, timeoutMs: in Int): Unit {
  g.deadlineNanos.set(JSystem.nanoTime() + timeoutMs.toLong() * 1000000i64)
  g.state.set(1i64)
}

// True when the write that just ran finished before the watchdog fired.
func disarmWrite(g: in WriteGuard): Bool {
  g.state.compareAndSet(1i64, 0i64)
}

func writeTimedOut(timeoutMs: in Int): TcpError {
  TransportFailed(message = "write timed out: the peer accepted no data for " + timeoutMs.toString() + " ms")
}

func writeWithin(c: in Conn, bytes: in slice[Byte], timeoutMs: in Int): Result[Unit, TcpError] {
  val g = c.guard
  val total = bytes.length
  try {
    armWrite(g, timeoutMs)
    if total <= writeChunkBytes {
      c.output.write(bytes)
    } else {
      var offset = 0
      while offset < total {
        val stop = if total - offset < writeChunkBytes { total } else { offset + writeChunkBytes }
        c.output.write(bytes.slice(offset, stop))
        offset = stop
        if offset < total {
          if g.state.get() != 1i64 {
            return Err(error = writeTimedOut(timeoutMs))
          }
          g.deadlineNanos.set(JSystem.nanoTime() + timeoutMs.toLong() * 1000000i64)
        }
      }
    }
    c.output.flush()
    if disarmWrite(g) {
      Ok(value = ())
    } else {
      Err(error = writeTimedOut(timeoutMs))
    }
  } catch Bug as b {
    if disarmWrite(g) {
      Err(error = TransportFailed(message = failureText(b.typeName, b.message)))
    } else {
      Err(error = writeTimedOut(timeoutMs))
    }
  }
}

/// Write all of `bytes` to the connection and flush. A broken pipe, a reset
/// connection or an I/O timeout is `Err(TransportFailed(...))` rather than an
/// uncaught exception. With an I/O timeout set, the progress rule of the
/// module header applies (a write of at most 64 KiB must complete within the
/// limit; a larger one gets a fresh window per 64 KiB chunk) and a timed-out
/// write closes the connection. Writes on one connection must not run
/// concurrently.
@experimental
pub func hostWrite(c: in Conn, bytes: in slice[Byte]): Result[Unit, TcpError] {
  try {
    val limit = c.timeoutMs.get().toInt()
    if limit == 0 {
      c.output.write(bytes)
      c.output.flush()
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

/// Interrupt a blocking `hostRead`/`hostWrite` in progress on this connection
/// FROM ANOTHER THREAD, without releasing the connection (that stays the owning
/// thread's job, via `hostClose`). Shuts down both directions of the underlying
/// TCP socket, for a plain and a TLS connection alike (module header): a
/// blocked read returns end of stream (an empty slice, or an `Err` on a TLS
/// connection whose peer sent no close_notify) and a blocked write fails with
/// `Err(TransportFailed(...))`. No TLS close_notify is sent. `hostClose` is
/// still required afterwards and is safe to call after a shutdown.
@experimental
pub func hostShutdown(c: in Conn): Unit {
  try {
    c.raw.shutdownInput()
  } catch Bug as _ {
    ()
  }
  try {
    c.raw.shutdownOutput()
  } catch Bug as _ {
    ()
  }
}

/// Close the connection, releasing the socket (and, for a TLS connection, the
/// `SSLSocket` over it). Swallows a double close.
@experimental
pub func hostClose(c: in Conn): Unit {
  val _ = guards.remove(c.guard)
  closeQuietly(c.socket)
  closeQuietly(c.raw)
}
