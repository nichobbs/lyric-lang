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
//! **Wired into CI**: the `lyric-web Undertow smoke on JVM` step of the
//! `compiler-self-tests-jvm` job runs `make maven-resolver`, restores this
//! manifest (a single-file jvm build reads the restored
//! `target/restore/jvm-classpath.txt`, and the bundle jar's manifest
//! `Class-Path` carries the restored Undertow jar paths so `java -jar`
//! needs no `-cp`), builds this file, and asserts all four endpoints.
//! Since #5571 the build resolves everything outside JVM codegen (workspace
//! deps with target-normalized features, `[project.packages]` bundling into
//! the single-file bundle), and the same command on `--target dotnet`
//! compiles and serves identically.  The JVM codegen blockers this header
//! used to document are fixed:
//!   - #5610 — an impl-method parameter typed with another package's record
//!     registered under the declaring file's own package (`req.body` here
//!     panicked with receiver `'Web/JvmServerSmoke/Request' has no known
//!     field or member 'body'`); instance-method parameter slots now resolve
//!     through the extern/imported-type seed, in lockstep with descriptors.
//!     This smoke is also #5610's regression pin — a two-package bundled
//!     compile with a cross-package impl param is not expressible in a
//!     single-file self-test.
//!   - #5444 — `self.mws[self.idx]` (a record FIELD of `slice[Middleware]`)
//!     erased its element to `Object`, so `mw.wrap(req, next)` fell through
//!     to auto-FFI on `java.lang.Object`; field elements now narrow via the
//!     `elem:<class>#<field>` registry (single-file regression cases live in
//!     `lyric-compiler/jvm/erased_element_checkcast_jvm_self_test.l` §6).
//!   - #5458 — a generic `extern type` alias (`JvmConcurrentDict[K, V]`)
//!     erased to `Object`, so `dict.get(key)` had no receiver class for
//!     auto-FFI.
//! #5443's general `[project.packages]` alias-collision bug remains open;
//! this library works around it via the `JvmConcurrentDict` rename (see
//! `_kernel/jvm/web_kernel.l`).
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
