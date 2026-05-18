// std/_kernel_jvm/http_server.l - JVM host boundary for a minimal
// synchronous HTTP server.
//
// Mirrors _kernel/http_server.l for the JVM target.  Routes through
// lyric.stdlib.jvm.HttpServerHost, which wraps
// com.sun.net.httpserver.HttpServer (built into the JDK; not a
// third-party dependency).
//
// HttpServerHandle wraps com.sun.net.httpserver.HttpServer.
// HttpContextHandle wraps com.sun.net.httpserver.HttpExchange,
// providing the same get/respond API as the .NET HttpListenerContext
// shim.
//
// Bootstrap-grade: synchronous, single-threaded, no router, no
// middleware.  The server loop blocks on nextContext() (backed by a
// blocking queue populated by the HttpServer's handler thread).
package Std.HttpServer

import Std.Core

extern type HttpListener = "lyric.stdlib.jvm.HttpServerHandle"
extern type HttpContext  = "lyric.stdlib.jvm.HttpContextHandle"

@externTarget("lyric.stdlib.jvm.HttpServerHost.startListener")
pub func startListener(prefix: in String): HttpListener = ()

@externTarget("lyric.stdlib.jvm.HttpServerHost.nextContext")
pub func nextContext(l: in HttpListener): HttpContext = ()

@externTarget("lyric.stdlib.jvm.HttpServerHost.stopListener")
pub func stopListener(l: in HttpListener): Unit = ()

@externTarget("lyric.stdlib.jvm.HttpServerHost.requestMethod")
pub func requestMethod(c: in HttpContext): String = ()

@externTarget("lyric.stdlib.jvm.HttpServerHost.requestPath")
pub func requestPath(c: in HttpContext): String = ()

@externTarget("lyric.stdlib.jvm.HttpServerHost.requestBody")
pub func requestBody(c: in HttpContext): String = ()

/// Reply with a plaintext body; closes the exchange.
@externTarget("lyric.stdlib.jvm.HttpServerHost.respondText")
pub func respondText(c: in HttpContext, status: in Int, body: in String): Unit = ()

/// Reply with application/json; closes the exchange.  Body passed
/// verbatim — pre-format with Std.Json.encodeString for string values.
@externTarget("lyric.stdlib.jvm.HttpServerHost.respondJson")
pub func respondJson(c: in HttpContext, status: in Int, body: in String): Unit = ()
