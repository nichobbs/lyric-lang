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
//! and `respondBytesWithHeaders` below.
//!
//! G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
//! the F# `Lyric.Stdlib.HttpServerHost` shim retires entirely.
//! Direct-extern primitives + Lyric-level orchestration live below.
//!
//! Chunked (streaming) responses: `beginChunkedResponse` commits
//! status/content-type/headers and switches the response into
//! `Transfer-Encoding: chunked` mode, returning the still-open output
//! stream; `streamWriteChunk` writes-and-flushes one chunk at a time
//! (surfacing a broken connection as `Err` rather than failing
//! silently); `endChunkedResponse` closes it. `lyric-web`
//! (`Web.serveStreaming`) builds its opt-in `StreamingHandler` route
//! table on top of these three (lyric-lang#5979). dotnet-only for now
//! — the JVM twin does not yet expose a streaming path (tracked
//! separately, see that twin's header).
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
pub extern type HttpListener = "System.Net.HttpListener"

pub extern type HttpContext = "System.Net.HttpListenerContext"

extern type WebHeaderCollection = "System.Net.WebHeaderCollection"

extern type HttpListenerRequest = "System.Net.HttpListenerRequest"

extern type HttpListenerResponse = "System.Net.HttpListenerResponse"

pub extern type Stream = "System.IO.Stream"

extern type StreamReader = "System.IO.StreamReader"

extern type Encoding = "System.Text.Encoding"

extern type Uri = "System.Uri"

extern type NetConvert = "System.Convert"

// =====================================================================
// Primitive helpers (private to this kernel file) — auto-FFI calls
// resolved from reference-assembly metadata: property gets via member
// access, property sets via assignment, ctors via `.new(args)`.
// =====================================================================
func ctxRequest(c: in HttpContext): HttpListenerRequest {
  c.Request
}

func ctxResponse(c: in HttpContext): HttpListenerResponse {
  c.Response
}

func requestUrl(req: in HttpListenerRequest): Uri {
  req.Url
}

func uriQuery(u: in Uri): String {
  u.Query
}

func uriUnescape(s: in String): String {
  Uri.UnescapeDataString(s)
}

func requestHeadersRaw(req: in HttpListenerRequest): WebHeaderCollection {
  req.Headers
}

func headersAllKeys(h: in WebHeaderCollection): slice[String] {
  h.AllKeys
}

// stays @externTarget: `Get(string)` is declared on the base class
// `NameValueCollection`, and auto-FFI instance resolution only searches
// the receiver's own TypeDef (no base-type walk on MSIL).
@externInstance
@externTarget("System.Collections.Specialized.NameValueCollection.Get")
func headersGet(h: in WebHeaderCollection, name: in String): String = ()

func responseAddHeader(resp: in HttpListenerResponse, name: in String, value: in String): Unit {
  resp.AddHeader(name, value)
}

func newStreamReader(stream: in Stream, encoding: in Encoding): StreamReader {
  StreamReader.new(stream, encoding)
}

func setResponseStatus(resp: in HttpListenerResponse, status: in Int): Unit {
  resp.StatusCode = status
}

func setResponseContentType(resp: in HttpListenerResponse, ct: in String): Unit {
  resp.ContentType = ct
}

func setResponseContentLength(resp: in HttpListenerResponse, len: in Long): Unit {
  resp.ContentLength64 = len
}

func responseOutputStream(resp: in HttpListenerResponse): Stream {
  resp.OutputStream
}

func streamWrite(s: in Stream, buffer: in slice[Byte], offset: in Int, count: in Int): Unit {
  s.Write(buffer, offset, count)
}

func streamClose(s: in Stream): Unit {
  s.Close()
}

func responseClose(resp: in HttpListenerResponse): Unit {
  resp.Close()
}

func utf8(): Encoding {
  Encoding.UTF8
}

func encodingGetBytes(e: in Encoding, s: in String): slice[Byte] {
  e.GetBytes(s)
}

func intToLong(n: in Int): Long {
  NetConvert.ToInt64(n)
}

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
  val resp = ctxResponse(c)
  setResponseStatus(resp, status)
  setResponseContentType(resp, contentType)
  val bytes = encodingGetBytes(utf8(), body)
  setResponseContentLength(resp, intToLong(bytes.length))
  val outStream = responseOutputStream(resp)
  streamWrite(outStream, bytes, 0, bytes.length)
  streamClose(outStream)
  responseClose(resp)
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

// =====================================================================
// Chunked (streaming) responses.
//
// A streaming response commits its status/content-type/headers up
// front — via `beginChunkedResponse` — instead of relying on the
// first `Stream.Write` to implicitly finalise them (the BCL permits
// mutating `HttpListenerResponse` up until the first write, but
// giving callers an explicit commit point is simpler to reason about
// than "committed by whichever write happens first"). No
// `Content-Length` is ever set: `SendChunked = true` puts the
// listener into `Transfer-Encoding: chunked` mode, which is what lets
// the body be of unknown/unbounded length.
// =====================================================================
func setResponseChunked(resp: in HttpListenerResponse): Unit {
  resp.SendChunked = true
}

func streamFlush(s: in Stream): Unit {
  s.Flush()
}

/// Set status + content-type + extra headers on `c`'s response, switch
/// it into chunked-transfer-encoding mode, and return the (still open)
/// output stream for the caller to write to repeatedly. No
/// `Content-Length` is set — chunked responses do not need one.
pub func beginChunkedResponse(
  c: in HttpContext, status: in Int, contentType: in String, headers: in Map[String, String]
): Stream {
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
  setResponseChunked(resp)
  return responseOutputStream(resp)
}

/// Write `bytes[offset..offset+count)` to a chunked-response stream and
/// flush it immediately, so the bytes are visible to the client before
/// the caller writes the next chunk. `Err` surfaces a broken connection
/// (e.g. the client disconnected mid-stream) instead of failing
/// silently — the message is the underlying BCL exception's `message`.
pub func streamWriteChunk(s: in Stream, bytes: in slice[Byte], offset: in Int, count: in Int): Result[Unit, String] {
  return try {
    streamWrite(s, bytes, offset, count)
    streamFlush(s)
    Ok(())
  } catch Bug as e {
    Err(e.message)
  }
}

/// Close a chunked-response stream and its underlying response, ending
/// the chunked body (a zero-length terminating chunk). Idempotent at
/// the BCL level, same as `stopListener`.
pub func endChunkedResponse(c: in HttpContext, s: in Stream): Unit {
  streamClose(s)
  responseClose(ctxResponse(c))
}
