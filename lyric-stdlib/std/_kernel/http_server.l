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
import extern System.IO.{Stream, StreamReader}
import extern System.Net.{HttpListener, HttpListenerContext as HttpContext, HttpListenerRequest, HttpListenerResponse, HttpListenerPrefixCollection}
import extern System.Text.{Encoding}
import extern System.{Uri}

// =====================================================================
// Primitive externs (private to this kernel file).
// =====================================================================
// Note: Constructors with arguments are wrapped manually to prevent stage-0
// seed compiler panics on metadata-based `.new(args)` calls.
@externTarget("System.IO.StreamReader..ctor")
func newStreamReader(stream: in Stream, encoding: in Encoding): StreamReader = ()

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
