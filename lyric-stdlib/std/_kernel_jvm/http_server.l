//! std/_kernel_jvm/http_server.l - JVM host boundary for a minimal
//! synchronous HTTP server.
//!
//! Mirrors _kernel/http_server.l for the JVM target: the same
//! twelve-function public surface (`startListener` / `nextContext` /
//! `stopListener` / `requestMethod` / `requestPath` / `requestBody` /
//! `requestQuery` / `requestHeaders` / `urlDecode` / `respondText` /
//! `respondJson` / `respondBytesWithHeaders`) over the JDK's built-in
//! `com.sun.net.httpserver.HttpServer` via the JVM auto-FFI.  The previous
//! version routed eight of the twelve through a phantom
//! `lyric.stdlib.jvm.HttpServerHost` class that never existed at runtime,
//! which left Std.HttpServer non-functional on this target (docs/59 F-1c,
//! docs/44 m-89; the four missing functions — `requestQuery` /
//! `requestHeaders` / `urlDecode` / `respondBytesWithHeaders` — are what
//! lyric-web's static-file and dispatch layers consume).
//!
//! The chunked-streaming helpers (`beginChunkedResponse` / `streamWriteChunk` /
//! `endChunkedResponse`) are provided here too, over the exchange's response
//! body (declaring a zero length switches `com.sun.net.httpserver` to chunked
//! transfer encoding).  `takeConnection` is not: the JDK server never exposes
//! the exchange's socket, so a protocol upgrade on this target is served by
//! Undertow in `lyric-ws` (`Ws.Kernel.Jvm`), a permanent difference rather than
//! a gap.
//!
//! Pull-model bridge: `HttpServer` is callback-based (`createContext(path,
//! HttpHandler)` invokes the handler on an executor thread) while this
//! kernel's contract is pull-based (`nextContext` blocks until a request
//! lands, like .NET's `HttpListener.GetContext`).  `startListener` bridges
//! the two with an unbounded `java.util.concurrent.LinkedBlockingQueue`:
//! the registered handler (a Lyric lambda SAM-bridged to `HttpHandler`)
//! only enqueues its `HttpExchange` and returns — the exchange stays open
//! after `handle()` returns until `close()` is called, which is the JDK's
//! documented asynchronous-completion pattern — and `nextContext` is a
//! genuinely blocking `queue.take()`.  The server runs on a
//! virtual-thread-per-task executor so handler dispatch never starves
//! under concurrent connections while exchanges wait in the queue.
//!
//! Behavioural notes vs the .NET twin (both are JDK contracts, not
//! omissions):
//!
//!   - `requestHeaders` keys arrive in `com.sun.net.httpserver.Headers`'
//!     normalized capitalization (first letter of each token upper-cased,
//!     the rest lowered: "X-Req" -> "X-req").  Header names are
//!     case-insensitive per RFC 7230, and consumers (e.g. lyric-web's
//!     `normalizeHeaders`) already fold case before lookup.  Multi-valued
//!     headers are comma-joined, matching the .NET twin's
//!     `WebHeaderCollection.Get` folding.
//!   - `requestBody` decodes as UTF-8 unconditionally; the .NET twin
//!     honours the request's declared content encoding.  UTF-8 is the
//!     interoperable default for every consumer this kernel has.
//!   - The request body is read, capped at 10 MiB (the dotnet server's
//!     default `EngineLimits.maxBodyBytes`), before the exchange is queued;
//!     a larger body is answered `413` and never reaches `nextContext`
//!     (#7269).
//!   - `https://` prefixes on `startListener` are still rejected loudly:
//!     that function's single-string-prefix shape has no room for a TLS
//!     config, so it always builds a plaintext `HttpServer`.  Real TLS
//!     termination ships via `startListenerTls` below (docs/61 §6.3,
//!     phase 2.1 of epic #5874, issue #5880) — the `#2663` gap this
//!     header used to describe as unimplemented is closed for the
//!     non-mTLS case; see `startListenerTls`'s own doc comment for the
//!     mTLS boundary (blocked on #5930, an `HttpsConfigurator`
//!     class-subclassing FFI gap).
//!
//! `startListenerTls`'s `SSLContext` comes from `Std.TlsServerContext`
//! (`_kernel_jvm/tls_server_context.l`), which owns the `KeyManagerFactory`/
//! `KeyStore` reflection bridge and the TLS 1.2 floor check and is shared with
//! `Std.TcpHost`; this package re-exports it (`pub use`), so
//! `serverSslContextFromConfig[Mtls]` and `ServerSslContext` stay reachable
//! through `Std.HttpServer` for `lyric-web`'s Undertow kernel (D621).
@axiom("com.sun.net.httpserver.HttpServer and HttpsServer operations conform to their documented JVM contracts")
@io
package Std.HttpServer

import Std.Core
import Std.Char
import Std.Collections
import Std.EncodingHost
import Std.Tls
import Std.TlsHost
import Std.String
import Std.TlsServerContext
pub use Std.TlsServerContext

// =====================================================================
// Extern types — JDK classes the helpers below reference.
// =====================================================================
@sendable
extern type JHttpServer = "com.sun.net.httpserver.HttpServer"

@experimental
pub extern type HttpContext = "com.sun.net.httpserver.HttpExchange"

extern type JHeaders = "com.sun.net.httpserver.Headers"

extern type JInetSocketAddress = "java.net.InetSocketAddress"

@sendable
extern type JQueue = "java.util.concurrent.LinkedBlockingQueue"

extern type JExecutors = "java.util.concurrent.Executors"

extern type JString = "java.lang.String"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JIterator = "java.util.Iterator"

extern type JSet = "java.util.Set"

extern type JList = "java.util.List"

extern type JHttpsServer = "com.sun.net.httpserver.HttpsServer"

extern type JObjects = "java.util.Objects"

extern type JHttpsConfigurator = "com.sun.net.httpserver.HttpsConfigurator"

extern type JSSLContext = "javax.net.ssl.SSLContext"

/// Failure returned by `startListenerTls`. Currently only `NotSupportedOnTarget`
/// exists: mutual TLS (`requireClientCert` / `clientCa`) cannot be built
/// on this target yet (see `startListenerTls`'s doc comment); a
/// non-mTLS `startListenerTls` call never returns `Err` on the JVM
/// target today.
@experimental
pub union TlsListenError {
  case NotSupportedOnTarget(message: String)
}

/// The listener handle: the running `HttpServer` plus the blocking queue
/// the SAM-bridged handler feeds and `nextContext` drains (module header).
/// A record rather than an extern alias because the pull-model bridge
/// needs both halves; the .NET twin's `HttpListener` alias is equally
/// opaque to consumers.
@experimental
pub record HttpListener {
  server: JHttpServer
  queue: JQueue
}

// =====================================================================
// Prefix parsing — pure Lyric.  Accepts the same shape the .NET twin's
// `HttpListener` prefixes use: "http://<host>:<port>/<path...>", where
// <host> may be "*" or "+" for a wildcard bind and the port defaults
// to 80 when absent.
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
    val c = charAtOrReplacement(text, i)
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
  path: String
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
    if rest.codeUnitAt(i) == '/'.toInt() {
      slashAt = i
    }
    i = i + 1
  }
  val hostPort = if slashAt >= 0 { rest.substring(0, slashAt) } else { rest }
  val path = if slashAt >= 0 { rest.substring(slashAt, rest.length - slashAt) } else { "/" }
  var colonAt = 0 - 1
  var j = 0
  while j < hostPort.length {
    if hostPort.codeUnitAt(j) == ':'.toInt() {
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
  ParsedPrefix(bindHost = bindHost, port = port, path = path)
}

// =====================================================================
// Public host helpers.
// =====================================================================
/// Construct + bind + start the server for `prefix` (e.g.
/// `"http://localhost:8080/"`).  The caller owns it and must call
/// `stopListener` on shutdown.  A `"*"` / `"+"` host binds the wildcard
/// address, matching the .NET twin's prefix convention.
@experimental
pub func startListener(prefix: in String): HttpListener {
  val parsed = parsePrefix(prefix)
  val addr = if parsed.bindHost == "*" or parsed.bindHost == "+" {
    JInetSocketAddress.new(parsed.port)
  } else {
    JInetSocketAddress.new(parsed.bindHost, parsed.port)
  }
  val server = JHttpServer.create(addr, 0)
  val queue = JQueue.new()
  // The handler only parks the exchange for `nextContext`; responding (and
  // closing) happens on the puller's thread — the JDK keeps an exchange
  // open after `handle()` returns until it is explicitly closed.
  server.createContext(parsed.path, { ex: HttpContext -> admitExchange(ex, queue) })
  server.setExecutor(JExecutors.newVirtualThreadPerTaskExecutor())
  server.start()
  HttpListener(server = server, queue = queue)
}

/// Construct + bind + start a TLS-terminated server on `host`:`port`,
/// built from `tls` (docs/61 §6.3, phase 2.1 of epic #5874, issue #5880).
/// The same pull-model bridge as `startListener` backs the returned
/// `HttpListener` — `nextContext`/`requestMethod`/…/`respondBytesWithHeaders`
/// work identically against a TLS listener; only construction differs.
/// A `"*"` / `"+"` host binds the wildcard address, matching
/// `startListener`'s convention. The context path is fixed at `"/"`
/// (`startListener`'s prefix-string form carries an optional path;
/// `startListenerTls`'s host/port/config shape has no room for one, and
/// every current consumer — `lyric-web`'s full-dispatch router — mounts
/// at the root anyway).
///
/// `tls.identity`'s certificate + private key become the server's TLS
/// identity via a `KeyManagerFactory`-backed `SSLContext`
/// (`serverSslContextFromConfig`); `tls.minVersion` restricts the
/// negotiated protocol range accordingly.
///
/// mTLS (`tls.requireClientCert` / `tls.clientCa`) is NOT yet supported
/// on this target: `com.sun.net.httpserver.HttpsServer` only applies
/// `HttpsParameters.setNeedClientAuth` through an application-supplied
/// `HttpsConfigurator.configure(...)` override, and overriding it
/// requires subclassing the concrete `HttpsConfigurator` class — Lyric's
/// `impl <ExternInterface> for Record` only implements interfaces
/// (verified empirically: `impl JHttpsConfigurator for Record` compiles
/// but throws `IncompatibleClassChangeError` at class-load time, since
/// `HttpsConfigurator` is not an interface). Requesting either field
/// returns `Err(NotSupportedOnTarget(...))` — a loud, typed rejection, never a
/// silent ignore — naming the tracking issue (#5930). Non-mTLS TLS
/// termination (identity + minVersion) is fully supported and never
/// returns `Err` on this target.
@experimental
pub func startListenerTls(host: in String, port: in Int, tls: in TlsServerConfig): Result[HttpListener, TlsListenError] {
  val mtlsRequested = tls.requireClientCert or match tls.clientCa { case Some(_) -> true; case None -> false }
  if mtlsRequested {
    return Err(
      error = NotSupportedOnTarget(
        message = "mutual TLS (requireClientCert / clientCa) is not yet supported on --target jvm: " +
          "com.sun.net.httpserver.HttpsServer requires overriding HttpsConfigurator.configure(...) " +
          "to call HttpsParameters.setNeedClientAuth, which needs subclassing the concrete " +
          "HttpsConfigurator class — Lyric's impl <ExternInterface> for Record only implements " +
          "interfaces (tracked in #5930)"
      )
    )
  }
  val ctx: JSSLContext = serverSslContextFromConfig(tls.identity, tls.minVersion).rawContext()
  val addr = if host == "*" or host == "+" { JInetSocketAddress.new(port) } else { JInetSocketAddress.new(host, port) }
  val httpsServer: JHttpsServer = JHttpsServer.create(addr, 0)
  httpsServer.setHttpsConfigurator(JHttpsConfigurator.new(ctx))
  val server: JHttpServer = JObjects.requireNonNull(httpsServer)
  val queue = JQueue.new()
  server.createContext("/", { ex: HttpContext -> admitExchange(ex, queue) })
  server.setExecutor(JExecutors.newVirtualThreadPerTaskExecutor())
  server.start()
  Ok(value = HttpListener(server = server, queue = queue))
}

/// Block until the next request lands (a genuine `queue.take()`).
@experimental
pub func nextContext(l: in HttpListener): HttpContext {
  val ex: HttpContext = l.queue.take()
  ex
}

/// Stop accepting connections immediately.
@experimental
pub func stopListener(l: in HttpListener): Unit {
  l.server.stop(0)
}

/// HTTP method (`"GET"`, `"POST"`, ...).  Returns `"GET"` if the
/// host throws — same defensive shape as the .NET twin.
@experimental
pub func requestMethod(c: in HttpContext): String {
  return try {
    c.getRequestMethod()
  } catch Bug as _ {
    "GET"
  }
}

/// Absolute path of the request target (everything before the first `?`),
/// still percent-escaped, as the .NET and native twins return it; decode a
/// segment with `urlDecode`.  Returns `"/"` if the host throws.
@experimental
pub func requestPath(c: in HttpContext): String {
  return try {
    c.getRequestURI().getRawPath() ?? "/"
  } catch Bug as _ {
    "/"
  }
}

/// Read the request body as a UTF-8 string (or `""` on transport error /
/// empty body). The body was read, bounded, before the request was queued
/// (`admitExchange`); this returns that stored text.
@experimental
pub func requestBody(c: in HttpContext): String {
  return try {
    storedBody(c)
  } catch Bug as _ {
    ""
  }
}

/// The request body's bytes, exactly as received (a binary upload, or text
/// in any encoding). `requestBody` is the UTF-8 text view of the same bytes.
/// Empty on a transport error, as `requestBody` is `""`.
@experimental
pub func requestBodyBytes(c: in HttpContext): slice[Byte] {
  val empty: slice[Byte] = []
  return try {
    storedBodyBytes(c)
  } catch Bug as _ {
    empty
  }
}

// Request bodies larger than this are answered `413` and never reach
// `nextContext`, the same cap the dotnet server applies by default
// (`EngineLimits.defaults().maxBodyBytes`, 10 MiB). Before #7269 the body was
// read on demand with an unbounded `readAllBytes`, so one request could
// allocate as much memory as its sender chose to send.
val maxRequestBodyBytes: Int = 10485760

// The `HttpExchange` attribute the admitted body is stored under.
val bodyAttribute: String = "lyric.requestBody"

// The admitted body is stored as an ISO-8859-1 `String`: one char per byte, so
// the exact bytes come back from `getBytes` and a binary body survives (a
// UTF-8 decode at admission replaced every malformed sequence).
// `HttpExchange.getAttribute` returns `Object`; `String.valueOf` turns the
// stored `String` back into one (and an absent attribute into "null", which
// `admitExchange` guarantees never happens for a queued exchange).
val bodyCarrierCharset: String = "ISO-8859-1"

func storedBodyBytes(c: in HttpContext): slice[Byte] {
  val carrier: JString = JString.valueOf(c.getAttribute(bodyAttribute))
  carrier.getBytes(bodyCarrierCharset)
}

func storedBody(c: in HttpContext): String {
  JString.new(storedBodyBytes(c), "UTF-8")
}

// Tail-position call: a discarded auto-FFI instance call on a parameter
// receiver is not emitted on the JVM (#5379).
func storeBody(c: in HttpContext, body: in String): Unit {
  c.setAttribute(bodyAttribute, body)
}

// Read the request body, bounded: `Some(carrier)` (see `bodyCarrierCharset`) when it fits in
// `maxRequestBodyBytes`, `None` when it is larger (at most `max + 1` bytes
// are ever read: one byte past the cap is proof enough). A transport failure
// reads as an empty body, as `requestBody` always has.
func readBoundedBody(c: in HttpContext): Option[String] {
  return try {
    val ins: JInputStream = c.getRequestBody()
    val bytes = ins.readNBytes(maxRequestBodyBytes)
    if ins.read() >= 0 {
      None
    } else {
      Some(value = JString.new(bytes, bodyCarrierCharset))
    }
  } catch Bug as _ {
    Some(value = "")
  }
}

// The `HttpHandler` body: read the request body (bounded), then either park
// the exchange for `nextContext` or answer `413` for an over-limit body
// without ever queuing it, as the dotnet server does.
func admitExchange(ex: in HttpContext, queue: in JQueue): Unit {
  match readBoundedBody(ex) {
    case Some(text) -> {
      storeBody(ex, text)
      queue.put(ex)
    }
    case None -> respondText(ex, 413, "request body exceeds " + toString(maxRequestBodyBytes) + " bytes")
  }
}

/// Raw query string with no leading `?` (e.g. `"a=1&b=2"`), still
/// percent-escaped — matching the .NET twin's `Uri.Query` handling — or
/// `""` if the URL has none or the host throws.
@experimental
pub func requestQuery(c: in HttpContext): String {
  return try {
    c.getRequestURI().getRawQuery() ?? ""
  } catch Bug as _ {
    ""
  }
}

/// Every request header as a name/value map.  Multi-valued headers are
/// comma-joined, matching HTTP's own multi-value-header folding rule
/// (RFC 7230 §3.2.2) and the .NET twin's `WebHeaderCollection.Get`.
/// Names carry the JDK's normalized capitalization ("X-req"; module
/// header) — treat them case-insensitively.  Returns an empty map if
/// the host throws.
@experimental
pub func requestHeaders(c: in HttpContext): Map[String, String] {
  val result: Map[String, String] = newMap()
  try {
    val h: JHeaders = c.getRequestHeaders()
    val names: JSet = h.keySet()
    val it: JIterator = names.iterator()
    while it.hasNext() {
      val name: String = it.next()
      val values: JList = h.get(name)
      val joined: String = JString.join(",", values)
      result.add(name, joined)
    }
  } catch Bug as _ {
    ()
  }
  return result
}

func isHexDigit(c: in Char): Bool {
  val cp = toInt(c);
  (cp >= 48 and cp <= 57) or (cp >= 97 and cp <= 102) or (cp >= 65 and cp <= 70)
}

func hexDigitValue(c: in Char): Int {
  val cp = toInt(c)
  if cp >= 48 and cp <= 57 {
    return cp - 48
  }
  if cp >= 97 and cp <= 102 {
    return cp - 97 + 10
  }
  cp - 65 + 10
}

// A `%XX` escape (two hex digits) starts at `i`.  Reads code units, so any
// text around the escapes — supplementary-plane characters included — is
// passed over rather than indexed as a `Char`.
func isPercentEscapeAt(s: in String, i: in Int): Bool {
  i + 2 < s.length and s.codeUnitAt(i) == 37 and isHexDigit(charAtOrReplacement(s, i + 1)) and
    isHexDigit(charAtOrReplacement(s, i + 2))
}

/// Percent-decode a URL-encoded string (query/path segment values),
/// matching `Uri.UnescapeDataString`: `%XX` runs decode as UTF-8 byte
/// sequences (a multi-byte code point spans consecutive `%XX` escapes,
/// so a whole run is collected before decoding), `+` is NOT treated as
/// a space, and malformed escapes pass through literally.
@experimental
pub func urlDecode(s: in String): String {
  val sb = StringBuilder.new()
  val len = s.length
  var litStart = 0
  var i = 0
  while i < len {
    if isPercentEscapeAt(s, i) {
      sb.append(s.substring(litStart, i - litStart))
      val bytes: List[Byte] = newList()
      while isPercentEscapeAt(s, i) {
        bytes.add((hexDigitValue(s[i + 1]) * 16 + hexDigitValue(s[i + 2])).toByte())
        i = i + 3
      }
      sb.append(JString.new(bytes.toArray(), "UTF-8"))
      litStart = i
    } else {
      i = i + 1
    }
  }
  sb.append(s.substring(litStart, len - litStart))
  sb.toString()
}

// Internal: shared response writer.  Sets Content-Type plus any extra
// headers (the JDK requires all headers set before sendResponseHeaders),
// sends the status line with the exact byte length (-1 for an empty body:
// the JDK's "no response body" marker), writes the body, then closes the
// exchange — which drains any unread request body and closes both
// streams, keeping the connection reusable.
// Sets the response `Content-Type` and the caller's extra headers on `c`.
func applyResponseHeaders(c: in HttpContext, contentType: in String, headers: in Map[String, String]): Unit {
  val respHeaders: JHeaders = c.getResponseHeaders()
  respHeaders.set("Content-Type", contentType)
  val names = mapKeys(headers).toArray()
  var i = 0
  while i < names.length {
    // Explicit String bindings force checkcasts: the slice element and the
    // Option payload are erased to Object, which Headers.add(String, String)
    // cannot take (the JVM verifier rejects the call) — same idiom as
    // _kernel_jvm/file_host.l's listChildren (#4816).
    val name: String = names[i]
    match mapGet(headers, name) {
      case Some(value) -> {
        val headerValue: String = value
        respHeaders.add(name, headerValue)
      }
      case None -> ()
    }
    i = i + 1
  }
}

func respondBytesWith(
  c: in HttpContext,
  status: in Int,
  contentType: in String,
  body: in slice[Byte],
  headers: in Map[String, String],
): Unit {
  applyResponseHeaders(c, contentType, headers)
  if body.length > 0 {
    c.sendResponseHeaders(status, body.length.toLong())
    val os: JOutputStream = c.getResponseBody()
    os.write(body)
    os.close()
  } else {
    c.sendResponseHeaders(status, 0i64 - 1i64)
  }
  c.close()
}

func respondWith(c: in HttpContext, status: in Int, contentType: in String, body: in String): Unit {
  val empty: Map[String, String] = newMap()
  respondBytesWith(c, status, contentType, hostEncodeUtf8("utf-8", body), empty)
}

/// Reply with a plaintext body; closes the exchange.
@experimental
pub func respondText(c: in HttpContext, status: in Int, body: in String): Unit {
  respondWith(c, status, "text/plain; charset=utf-8", body)
}

/// Reply with `application/json`; closes the exchange.  The body is
/// passed through verbatim — pre-format with `Std.Json.encodeString`
/// and string-concat for primitive payloads, or hand-build complex
/// shapes.
@experimental
pub func respondJson(c: in HttpContext, status: in Int, body: in String): Unit {
  respondWith(c, status, "application/json; charset=utf-8", body)
}

/// Reply with a raw byte body plus extra response headers; closes the
/// exchange.
@experimental
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
// Chunked streaming (the `Std.HttpServer` twin of the dotnet and native
// helpers of the same names).  `com.sun.net.httpserver` switches an exchange
// to chunked transfer encoding when the response length is declared as 0.
// =====================================================================
/// An open chunked response: the exchange's response body stream.
@experimental
pub record HttpChunkedStream {
  body: JOutputStream
}

/// Commit status + content-type + extra headers, switch the response into
/// chunked-transfer-encoding mode, and return the open stream handle to write
/// chunks to.  No `Content-Length` is set.
@experimental
pub func beginChunkedResponse(
  c: in HttpContext, status: in Int, contentType: in String, headers: in Map[String, String]
): HttpChunkedStream {
  if status < 100 or status > 999 {
    panic("HTTP response status must be a three-digit code (100..999), got " + toString(status))
  }
  applyResponseHeaders(c, contentType, headers)
  sendChunkedHeaders(c, status)
  HttpChunkedStream(body = c.getResponseBody())
}

// Tail-position forms: a discarded auto-FFI instance call whose receiver is a
// parameter emits no invoke on this backend (#5379).
func sendChunkedHeaders(c: in HttpContext, status: in Int): Unit {
  c.sendResponseHeaders(status, 0i64)
}

func writeBodyRange(os: in JOutputStream, bytes: in slice[Byte], offset: in Int, count: in Int): Unit {
  os.write(bytes, offset, count)
}

func flushBody(os: in JOutputStream): Unit {
  os.flush()
}

func closeBody(os: in JOutputStream): Unit {
  os.close()
}

func closeExchange(c: in HttpContext): Unit {
  c.close()
}

/// Write `bytes[offset..offset+count)` as one chunk and flush it immediately.
/// A zero-length write is a no-op.  `Err` surfaces a broken connection.
@experimental
pub func streamWriteChunk(
  s: in HttpChunkedStream, bytes: in slice[Byte], offset: in Int, count: in Int
): Result[Unit, String] {
  if count <= 0 {
    return Ok(value = ())
  }
  try {
    writeBodyRange(s.body, bytes, offset, count)
    flushBody(s.body)
    Ok(value = ())
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// Write the terminating chunk and complete the exchange.  A broken
/// connection is swallowed: a disconnect mid-stream is routine.
@experimental
pub func endChunkedResponse(c: in HttpContext, s: in HttpChunkedStream): Unit {
  try {
    closeBody(s.body)
  } catch Bug as _ {
    ()
  }
  closeExchange(c)
}
