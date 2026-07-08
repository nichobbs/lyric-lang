//! tests/jvm_server_smoke.l — real end-to-end HTTP round trip against the
//! Undertow-backed `Web.Kernel.Runtime` server on `--target jvm`.
//!
//! Mirrors `examples/rest_service.l`'s CI smoke-test shape (`.github/
//! workflows/ci.yml`'s "smoke examples/rest_service.l" step): start the
//! server as a background process, `curl` it, assert on the response, kill
//! it.  Unlike `dispatch_tests.l` (which exercises `Web.dispatch` directly,
//! no real socket), this file starts a *real* Undertow listener and drives
//! it with a real HTTP client, proving routing, status codes, headers, a
//! path parameter, and the request body round trip through actual
//! `io.undertow.server.HttpServerExchange` I/O — not just the pure
//! dispatch core.
//!
//! Endpoints:
//!   GET  /hello/{name}   -> 200 text, greets `name` (path param)
//!   GET  /echo-header    -> 200 JSON echoing the `X-Test` request header
//!   POST /echo-body      -> 200 text echoing the request body
//!   GET  /nope           -> 404 (no matching route)
//!
//! Run:
//!   lyric run --target jvm tests/jvm_server_smoke.l &
//!   curl -s http://localhost:8099/hello/Ada
//!   curl -s -H 'X-Test: abc' http://localhost:8099/echo-header
//!   curl -s -X POST --data 'ping' http://localhost:8099/echo-body
//!   curl -s -o /dev/null -w '%{http_code}' http://localhost:8099/nope
//!
//! **Not yet wired into CI as an automated smoke test.**  Two newly-found
//! JVM backend bugs (neither is #1707 — that ticket is closed and covers a
//! different, narrower nested-generic-construction defect) block the rest
//! of this library's JVM test suite from compiling at all: #5443 (a
//! `[project.packages]` multi-file-same-package entry leaking the
//! non-selected file's `extern type` binding) and #5444 (an interface-typed
//! `List`/`slice` element erasing to `Object` without a checkcast before a
//! method call, crashing auto-FFI resolution).  This file, `Web.Kernel.
//! Runtime`'s Undertow implementation, and the `impl JHttpHandler for
//! LyricUndertowHandler` interface binding were verified by hand (a
//! from-scratch `impl <ExternInterface> for Record` repro against
//! `java.lang.Runnable`, run under `java`, plus `lyric-compiler/jvm/
//! ffi_iface_impl_jvm_self_test.l`) independent of #5443/#5444.  Once those
//! land, re-run this file's manual steps above and wire it into `ci.yml`
//! alongside the existing dotnet `rest_service.l` smoke test.
package Web.JvmServerSmoke

import Std.Core
import Std.Collections
import Web

record HelloHandler {
}

impl Web.Handler for HelloHandler {
  func handle(req: in Web.Request): Web.Response {
    match Web.pathParam(req, "name") {
      case Some(name) -> Web.text(200, "Hello, " + name + "!")
      case None -> Web.errorResponse(Web.badRequest("missing name"))
    }
  }
}

record EchoHeaderHandler {
}

impl Web.Handler for EchoHeaderHandler {
  func handle(req: in Web.Request): Web.Response {
    val value = match Web.header(req, "X-Test") { case Some(v) -> v; case None -> "" }
    Web.json(200, "{\"xTest\":\"" + value + "\"}")
  }
}

record EchoBodyHandler {
}

impl Web.Handler for EchoBodyHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, req.body)
  }
}

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router, "/hello/{name}", HelloHandler())
  router = Web.addGet(router, "/echo-header", EchoHeaderHandler())
  router = Web.addPost(router, "/echo-body", EchoBodyHandler())
  Web.serve(router, "0.0.0.0", 8099)
}
