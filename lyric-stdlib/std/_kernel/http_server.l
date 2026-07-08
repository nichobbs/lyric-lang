//! std/http_server.l - Tiny HTTP server on top of `HttpListener`.
//!
//! The canonical loop is:
//!
//!   func main(): Unit {
//!     val srv = startListener("http://localhost:8080/")
//!     while true {
//!       val ctx = nextContext(srv)
//!       val method = requestMethod(ctx)
//!       val path = requestPath(ctx)
//!       respondJson(ctx, 200, "{\"hello\": \"world\"}")
//!     }
//!   }
//!
//! Bootstrap-grade: synchronous, single-threaded, no router, no
//! middleware.  Good enough to demonstrate end-to-end REST shape;
//! real servers come later (or via a hand-curated wrapper around
//! ASP.NET Core minimal APIs).  `lyric-web` (`Web.start`) builds its
//! router, middleware pipeline, and static file serving on top of
//! this kernel — see `requestQuery`, `requestHeaders`, `urlDecode`,
//! `respondBytes`, and `respondBytesWithHeaders` below.
//!
//! G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
//! the F# `Lyric.Stdlib.HttpServerHost` shim retires entirely.
//! Direct-extern primitives + Lyric-level orchestration live below.
//!
//! dotnet-only: the JVM twin (`_kernel_jvm/http_server.l`) routes
//! through an out-of-repo prebuilt JAR (`lyric.stdlib.jvm.HttpServerHost`)
//! and does not yet expose query string / header / byte-body support —
//! a pre-existing Phase-6 JVM-parity gap (see `docs/44`), not one this
//! extension introduces.
package Std.HttpServer

import Std.Core
import Std.Collections

// =====================================================================
// Extern types — BCL classes the helpers below reference.
// =====================================================================
import extern System.IO.{Stream, StreamReader}
import extern System.Net.{HttpListener, HttpListenerContext as HttpContext, HttpListenerRequest, HttpListenerResponse, HttpListenerPrefixCollection}
import extern System.Text.{Encoding}
import extern System.{Uri}

extern type WebHeaderCollection = "System.Net.WebHeaderCollection"

// =====================================================================
// Primitive externs (private to this kernel file).
// =====================================================================
// Note: Constructors with arguments are wrapped manually to prevent stage-0
// seed compiler panics on metadata-based `.new(args)` calls.
@externTarget("System.Net.HttpListener..ctor")
func newHttpListener(): HttpListener = ()

// .NET properties are exposed as `get_<Name>` / `set_<Name>` methods
// on the declaring type; @externTarget binds to method names, not property
// names, so each property reader/writer must use the prefixed form.  Instance
// properties also need `@externInstance` so the FFI emitter routes through
// callvirt instead of treating them as static calls.
@externInstance
@externTarget("System.Net.HttpListener.get_Prefixes")
func listenerPrefixes(l: in HttpListener): HttpListenerPrefixCollection = ()

@externInstance
@externTarget("System.Net.HttpListenerPrefixCollection.Add")
func prefixesAdd(p: in HttpListenerPrefixCollection, prefix: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpListener.Start")
func listenerStart(l: in HttpListener): Unit = ()

@externInstance
@externTarget("System.Net.HttpListener.GetContext")
func listenerGetContext(l: in HttpListener): HttpContext = ()

@externInstance
@externTarget("System.Net.HttpListener.Stop")
func listenerStop(l: in HttpListener): Unit = ()

@externInstance
@externTarget("System.Net.HttpListenerContext.get_Request")
func ctxRequest(c: in HttpContext): HttpListenerRequest = ()

@externInstance
@externTarget("System.Net.HttpListenerContext.get_Response")
func ctxResponse(c: in HttpContext): HttpListenerResponse = ()

@externInstance
@externTarget("System.Net.HttpListenerRequest.get_HttpMethod")
func requestHttpMethod(req: in HttpListenerRequest): String = ()

@externInstance
@externTarget("System.Net.HttpListenerRequest.get_Url")
func requestUrl(req: in HttpListenerRequest): Uri = ()

@externInstance
@externTarget("System.Uri.get_AbsolutePath")
func uriAbsolutePath(u: in Uri): String = ()

@externInstance
@externTarget("System.Uri.get_Query")
func uriQuery(u: in Uri): String = ()

@externTarget("System.Uri.UnescapeDataString")
func uriUnescape(s: in String): String = ()

@externInstance
@externTarget("System.Net.HttpListenerRequest.get_Headers")
func requestHeadersRaw(req: in HttpListenerRequest): WebHeaderCollection = ()

@externInstance
@externTarget("System.Net.WebHeaderCollection.get_AllKeys")
func headersAllKeys(h: in WebHeaderCollection): slice[String] = ()

@externInstance
@externTarget("System.Collections.Specialized.NameValueCollection.Get")
func headersGet(h: in WebHeaderCollection, name: in String): String = ()

@externInstance
@externTarget("System.Net.HttpListenerResponse.AddHeader")
func responseAddHeader(resp: in HttpListenerResponse, name: in String, value: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpListenerRequest.get_InputStream")
func requestInputStream(req: in HttpListenerRequest): Stream = ()

@externInstance
@externTarget("System.Net.HttpListenerRequest.get_ContentEncoding")
func requestContentEncoding(req: in HttpListenerRequest): Encoding = ()
@externTarget("System.IO.StreamReader..ctor")
func newStreamReader(stream: in Stream, encoding: in Encoding): StreamReader = ()

@externInstance
@externTarget("System.IO.StreamReader.ReadToEnd")
func readerReadToEnd(r: in StreamReader): String = ()

@externInstance
@externTarget("System.Net.HttpListenerResponse.set_StatusCode")
func setResponseStatus(resp: in HttpListenerResponse, status: in Int): Unit = ()

@externInstance
@externTarget("System.Net.HttpListenerResponse.set_ContentType")
func setResponseContentType(resp: in HttpListenerResponse, ct: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpListenerResponse.set_ContentLength64")
func setResponseContentLength(resp: in HttpListenerResponse, len: in Long): Unit = ()

@externInstance
@externTarget("System.Net.HttpListenerResponse.get_OutputStream")
func responseOutputStream(resp: in HttpListenerResponse): Stream = ()

@externInstance
@externTarget("System.IO.Stream.Write")
func streamWrite(s: in Stream, buffer: in slice[Byte], offset: in Int, count: in Int): Unit = ()

@externInstance
@externTarget("System.IO.Stream.Close")
func streamClose(s: in Stream): Unit = ()

@externInstance
@externTarget("System.Net.HttpListenerResponse.Close")
func responseClose(resp: in HttpListenerResponse): Unit = ()

@externTarget("System.Text.Encoding.get_UTF8")
func utf8(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func encodingGetBytes(e: in Encoding, s: in String): slice[Byte] = ()

@externTarget("System.Convert.ToInt64")
func intToLong(n: in Int): Long = ()

// =====================================================================
// Public host helpers.
// =====================================================================
/// Construct + bind + start the listener for `prefix` (e.g.
/// `"http://localhost:8080/"`).  The caller owns it and must call
/// `stopListener` on shutdown.
pub func startListener(prefix: in String): HttpListener {
  val l = HttpListener.new()
  l.get_Prefixes().Add(prefix)
  l.Start()
  l
}

/// Block until the next request lands.
pub func nextContext(l: in HttpListener): HttpContext {
  l.GetContext()
}

/// Stop accepting connections.  Idempotent at the BCL level.
pub func stopListener(l: in HttpListener): Unit {
  l.Stop()
}

/// HTTP method (`"GET"`, `"POST"`, …).  Returns `"GET"` if the
/// host throws — same defensive shape the previous F# shim had.
pub func requestMethod(c: in HttpContext): String {
  return try {
    c.get_Request().get_HttpMethod()
  } catch Bug as _ {
    "GET"
  }
}

/// Absolute path of the request URL.  Returns `"/"` if the URL is
/// missing or the host throws — same defensive shape as before.
pub func requestPath(c: in HttpContext): String {
  return try {
    c.get_Request().get_Url().get_AbsolutePath()
  } catch Bug as _ {
    "/"
  }
}

/// Read the request body as a UTF-8 string (or `""` on transport
/// error / empty body).  The `StreamReader` is leaked deliberately
/// — the BCL closes it implicitly when the request completes, and
/// a Lyric-level `defer { reader.dispose() }` would need
/// `IDisposable` plumbing this slice doesn't yet have.
pub func requestBody(c: in HttpContext): String {
  return try {
    val req = c.get_Request()
    val reader = newStreamReader(req.get_InputStream(), req.get_ContentEncoding())
    reader.ReadToEnd()
  } catch Bug as _ {
    ""
  }
}

/// Raw query string with no leading `?` (e.g. `"a=1&b=2"`), or `""` if
/// the URL has none or the host throws.
pub func requestQuery(c: in HttpContext): String {
  return try {
    val q = uriQuery(requestUrl(ctxRequest(c)))
    if q.length > 0 and q[0] == '?' {
      q.substring(1)
    } else {
      q
    }
  } catch Bug as _ {
    ""
  }
}

/// Every request header as a name/value map.  Multi-valued headers are
/// comma-joined by the BCL's `WebHeaderCollection.Get`, matching HTTP's
/// own multi-value-header folding rule (RFC 7230 §3.2.2).  Returns an
/// empty map if the host throws.
pub func requestHeaders(c: in HttpContext): Map[String, String] {
  val result: Map[String, String] = newMap()
  try {
    val h = requestHeadersRaw(ctxRequest(c))
    val names = headersAllKeys(h)
    var i = 0
    while i < names.length {
      val name = names[i]
      result.add(name, headersGet(h, name))
      i = i + 1
    }
  } catch Bug as _ {
    ()
  }
  return result
}

/// Percent-decode a URL-encoded string (query/path segment values).
pub func urlDecode(s: in String): String {
  return try {
    uriUnescape(s)
  } catch Bug as _ {
    s
  }
}

// Internal: shared response writer for both the text and JSON helpers.
// Sets status + content-type, encodes the body to UTF-8 bytes, writes
// the full buffer, then closes the output stream and the response.
func respondWith(c: in HttpContext, status: in Int, contentType: in String, body: in String): Unit {
  val resp = c.get_Response()
  resp.set_StatusCode(status)
  resp.set_ContentType(contentType)
  val bytes = Encoding.get_UTF8().GetBytes(body)
  resp.set_ContentLength64(intToLong(bytes.length))
  val outStream = resp.get_OutputStream()
  outStream.Write(bytes, 0, bytes.length)
  outStream.Close()
  resp.Close()
}

/// Reply with a plaintext body; closes the response.
pub func respondText(c: in HttpContext, status: in Int, body: in String): Unit {
  respondWith(c, status, "text/plain; charset=utf-8", body)
}

/// Reply with `application/json`; closes the response.  The body is
/// passed through verbatim — pre-format with `Std.Json.encodeString`
/// and string-concat for primitive payloads, or hand-build complex
/// shapes.
pub func respondJson(c: in HttpContext, status: in Int, body: in String): Unit {
  respondWith(c, status, "application/json; charset=utf-8", body)
}

// Internal: shared byte-body response writer.  Extra headers are added
// before the body is written (the BCL requires headers to be set before
// the first write to the output stream).
func respondBytesWith(
  c: in HttpContext,
  status: in Int,
  contentType: in String,
  body: in slice[Byte],
  headers: in Map[String, String],
): Unit {
  val resp = ctxResponse(c)
  setResponseStatus(resp, status)
  setResponseContentType(resp, contentType)
  val names = mapKeys(headers).toArray()
  var i = 0
  while i < names.length {
    val name = names[i]
    match mapGet(headers, name) {
      case Some(value) -> responseAddHeader(resp, name, value)
      case None -> ()
    }
    i = i + 1
  }
  setResponseContentLength(resp, intToLong(body.length))
  val outStream = responseOutputStream(resp)
  streamWrite(outStream, body, 0, body.length)
  streamClose(outStream)
  responseClose(resp)
}

/// Reply with a raw byte body (e.g. a static file, an image, a binary
/// download); closes the response.
pub func respondBytes(c: in HttpContext, status: in Int, contentType: in String, body: in slice[Byte]): Unit {
  respondBytesWith(c, status, contentType, body, newMap())
}

/// Reply with a raw byte body plus extra response headers; closes the
/// response.
pub func respondBytesWithHeaders(
  c: in HttpContext,
  status: in Int,
  contentType: in String,
  body: in slice[Byte],
  headers: in Map[String, String],
): Unit {
  respondBytesWith(c, status, contentType, body, headers)
}
