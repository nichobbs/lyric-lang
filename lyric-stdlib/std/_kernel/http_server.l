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
//! ASP.NET Core minimal APIs).
//!
//! G12 (`docs/23-fsharp-shim-elimination.md` §5; D-progress-NNN):
//! the F# `Lyric.Stdlib.HttpServerHost` shim retires entirely.
//! Direct-extern primitives + Lyric-level orchestration live below.
package Std.HttpServer

import Std.Core

// =====================================================================
// Extern types — BCL classes the helpers below reference.
// =====================================================================
extern type HttpListener = "System.Net.HttpListener"

extern type HttpContext = "System.Net.HttpListenerContext"

extern type HttpListenerRequest = "System.Net.HttpListenerRequest"

extern type HttpListenerResponse = "System.Net.HttpListenerResponse"

extern type HttpListenerPrefixCollection = "System.Net.HttpListenerPrefixCollection"

extern type Uri = "System.Uri"

extern type Encoding = "System.Text.Encoding"

extern type Stream = "System.IO.Stream"

extern type StreamReader = "System.IO.StreamReader"

// =====================================================================
// Primitive externs (private to this kernel file).
// =====================================================================
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
  val l = newHttpListener()
  prefixesAdd(listenerPrefixes(l), prefix)
  listenerStart(l)
  l
}

/// Block until the next request lands.
pub func nextContext(l: in HttpListener): HttpContext {
  listenerGetContext(l)
}

/// Stop accepting connections.  Idempotent at the BCL level.
pub func stopListener(l: in HttpListener): Unit {
  listenerStop(l)
}

/// HTTP method (`"GET"`, `"POST"`, …).  Returns `"GET"` if the
/// host throws — same defensive shape the previous F# shim had.
pub func requestMethod(c: in HttpContext): String {
  return try {
    requestHttpMethod(ctxRequest(c))
  } catch Bug as _ {
    "GET"
  }
}

/// Absolute path of the request URL.  Returns `"/"` if the URL is
/// missing or the host throws — same defensive shape as before.
pub func requestPath(c: in HttpContext): String {
  return try {
    uriAbsolutePath(requestUrl(ctxRequest(c)))
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
    val req = ctxRequest(c)
    val reader = newStreamReader(requestInputStream(req), requestContentEncoding(req))
    readerReadToEnd(reader)
  } catch Bug as _ {
    ""
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
