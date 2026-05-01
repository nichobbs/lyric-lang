// std/http_server.l - Tiny HTTP server on top of `HttpListener`.
//
// The canonical loop is:
//
//   func main(): Unit {
//     val srv = startListener("http://localhost:8080/")
//     while true {
//       val ctx = nextContext(srv)
//       val method = requestMethod(ctx)
//       val path = requestPath(ctx)
//       respondJson(ctx, 200, "{\"hello\": \"world\"}")
//     }
//   }
//
// Bootstrap-grade: synchronous, single-threaded, no router, no
// middleware.  Good enough to demonstrate end-to-end REST shape;
// real servers come later (or via a hand-curated wrapper around
// ASP.NET Core minimal APIs).
package Std.HttpServer

import Std.Core

extern type HttpListener = "System.Net.HttpListener"
extern type HttpContext  = "System.Net.HttpListenerContext"

@externTarget("Lyric.Stdlib.HttpServerHost.StartListener")
pub func startListener(prefix: in String): HttpListener = ()

@externTarget("Lyric.Stdlib.HttpServerHost.NextContext")
pub func nextContext(l: in HttpListener): HttpContext = ()

@externTarget("Lyric.Stdlib.HttpServerHost.StopListener")
pub func stopListener(l: in HttpListener): Unit = ()

@externTarget("Lyric.Stdlib.HttpServerHost.RequestMethod")
pub func requestMethod(c: in HttpContext): String = ()

@externTarget("Lyric.Stdlib.HttpServerHost.RequestPath")
pub func requestPath(c: in HttpContext): String = ()

@externTarget("Lyric.Stdlib.HttpServerHost.RequestBody")
pub func requestBody(c: in HttpContext): String = ()

/// Reply with a plaintext body; closes the response.
@externTarget("Lyric.Stdlib.HttpServerHost.RespondText")
pub func respondText(c: in HttpContext, status: in Int, body: in String): Unit = ()

/// Reply with `application/json`; closes the response.  The body is
/// passed through verbatim — pre-format with `Std.Json.encodeString`
/// and string-concat for primitive payloads, or hand-build complex
/// shapes.
@externTarget("Lyric.Stdlib.HttpServerHost.RespondJson")
pub func respondJson(c: in HttpContext, status: in Int, body: in String): Unit = ()
