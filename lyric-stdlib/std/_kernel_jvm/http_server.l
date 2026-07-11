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
//!   - `https://` prefixes are rejected loudly: `HttpsServer` needs TLS
//!     keystore configuration this kernel surface has no way to carry
//!     (tracked with the JVM parity umbrella, #2663).  The .NET twin
//!     inherits OS-level certificate binding from `HttpListener` instead.
@axiom("com.sun.net.httpserver.HttpServer operations conform to their documented JVM contracts")
package Std.HttpServer

import Std.Core
import Std.Char
import Std.Collections
import Std.EncodingHost

// =====================================================================
// Extern types — JDK classes the helpers below reference.
// =====================================================================
extern type JHttpServer = "com.sun.net.httpserver.HttpServer"

pub extern type HttpContext = "com.sun.net.httpserver.HttpExchange"

extern type JHeaders = "com.sun.net.httpserver.Headers"

extern type JInetSocketAddress = "java.net.InetSocketAddress"

extern type JQueue = "java.util.concurrent.LinkedBlockingQueue"

extern type JExecutors = "java.util.concurrent.Executors"

extern type JString = "java.lang.String"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JIterator = "java.util.Iterator"

extern type JSet = "java.util.Set"

extern type JList = "java.util.List"

/// The listener handle: the running `HttpServer` plus the blocking queue
/// the SAM-bridged handler feeds and `nextContext` drains (module header).
/// A record rather than an extern alias because the pull-model bridge
/// needs both halves; the .NET twin's `HttpListener` alias is equally
/// opaque to consumers.
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
    val c = text[i]
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
      "Std.HttpServer: https listener prefixes are not supported on the JVM target: " +
        "com.sun.net.httpserver.HttpsServer requires TLS keystore configuration this " +
        "kernel surface cannot carry (tracked in #2663)"
    )
  }
  if not prefix.startsWith("http://") {
    panic("Std.HttpServer: invalid listener prefix '" + prefix + "': expected \"http://host:port/\"")
  }
  val rest = prefix.substring(7, prefix.length - 7)
  var slashAt = 0 - 1
  var i = 0
  while i < rest.length and slashAt < 0 {
    if rest[i] == '/' {
      slashAt = i
    }
    i = i + 1
  }
  val hostPort = if slashAt >= 0 { rest.substring(0, slashAt) } else { rest }
  val path = if slashAt >= 0 { rest.substring(slashAt, rest.length - slashAt) } else { "/" }
  var colonAt = 0 - 1
  var j = 0
  while j < hostPort.length {
    if hostPort[j] == ':' {
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
  server.createContext(parsed.path, { ex: HttpContext -> queue.put(ex); () })
  server.setExecutor(JExecutors.newVirtualThreadPerTaskExecutor())
  server.start()
  HttpListener(server = server, queue = queue)
}

/// Block until the next request lands (a genuine `queue.take()`).
pub func nextContext(l: in HttpListener): HttpContext {
  val ex: HttpContext = l.queue.take()
  ex
}

/// Stop accepting connections immediately.
pub func stopListener(l: in HttpListener): Unit {
  l.server.stop(0)
}

/// HTTP method (`"GET"`, `"POST"`, ...).  Returns `"GET"` if the
/// host throws — same defensive shape as the .NET twin.
pub func requestMethod(c: in HttpContext): String {
  return try {
    c.getRequestMethod()
  } catch Bug as _ {
    "GET"
  }
}

/// Absolute path of the request URL.  Returns `"/"` if the host
/// throws — same defensive shape as the .NET twin.
pub func requestPath(c: in HttpContext): String {
  return try {
    c.getRequestURI().getPath() ?? "/"
  } catch Bug as _ {
    "/"
  }
}

/// Read the request body as a UTF-8 string (or `""` on transport error /
/// empty body).  The stream is not closed here: `HttpExchange.close()`
/// (called by every respond helper) drains and closes both directions.
pub func requestBody(c: in HttpContext): String {
  return try {
    val ins: JInputStream = c.getRequestBody()
    val bytes = ins.readAllBytes()
    JString.new(bytes, "UTF-8")
  } catch Bug as _ {
    ""
  }
}

/// Raw query string with no leading `?` (e.g. `"a=1&b=2"`), still
/// percent-escaped — matching the .NET twin's `Uri.Query` handling — or
/// `""` if the URL has none or the host throws.
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

/// Percent-decode a URL-encoded string (query/path segment values),
/// matching `Uri.UnescapeDataString`: `%XX` runs decode as UTF-8 byte
/// sequences (a multi-byte code point spans consecutive `%XX` escapes,
/// so a whole run is collected before decoding), `+` is NOT treated as
/// a space, and malformed escapes pass through literally.
pub func urlDecode(s: in String): String {
  var result = ""
  val len = s.length
  var i = 0
  while i < len {
    val c = s[i]
    if c == '%' and i + 2 < len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2]) {
      val bytes: List[Byte] = newList()
      while i + 2 < len and s[i] == '%' and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2]) {
        bytes.add(hexDigitValue(s[i + 1]) * 16 + hexDigitValue(s[i + 2]))
        i = i + 3
      }
      result = result + JString.new(bytes.toArray(), "UTF-8")
    } else {
      result = result + ("" + c)
      i = i + 1
    }
  }
  result
}

// Internal: shared response writer.  Sets Content-Type plus any extra
// headers (the JDK requires all headers set before sendResponseHeaders),
// sends the status line with the exact byte length (-1 for an empty body:
// the JDK's "no response body" marker), writes the body, then closes the
// exchange — which drains any unread request body and closes both
// streams, keeping the connection reusable.
func respondBytesWith(
  c: in HttpContext,
  status: in Int,
  contentType: in String,
  body: in slice[Byte],
  headers: in Map[String, String],
): Unit {
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
  if body.length > 0 {
    c.sendResponseHeaders(status, intToLong(body.length))
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
pub func respondText(c: in HttpContext, status: in Int, body: in String): Unit {
  respondWith(c, status, "text/plain; charset=utf-8", body)
}

/// Reply with `application/json`; closes the exchange.  The body is
/// passed through verbatim — pre-format with `Std.Json.encodeString`
/// and string-concat for primitive payloads, or hand-build complex
/// shapes.
pub func respondJson(c: in HttpContext, status: in Int, body: in String): Unit {
  respondWith(c, status, "application/json; charset=utf-8", body)
}

/// Reply with a raw byte body plus extra response headers; closes the
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
