//! tests/serve_crash_isolation_tests.l — end-to-end regression pin for
//! `Web.serve()`/`Web.serveStreaming()`'s per-request crash isolation
//! (#5261, a review finding on #5259/#5260: a caught `Bug` while handling
//! one request used to close the listener and call `Env.exitCode(1)`,
//! taking the whole server down over a single bad request).
//!
//! `serveStreaming` (which `serve` now delegates to, #5990) wraps
//! `tryNextContext` and per-request handling in separate `try`/`catch Bug`
//! blocks: a handler panic (or any other `Bug` raised while building the
//! request, dispatching it, or writing the response) is logged and
//! answered with a 500 for that request only — the accept loop keeps
//! running and serves the next request normally. Only a failure in
//! `tryNextContext` itself (the listener can no longer accept connections
//! at all) remains fatal.
//!
//! This drives a REAL `Web.serve` listener in-process (a background thread
//! from `Std.HttpServerHost` + a real Lyric `HttpClient`, as
//! `tests/serve_tls_tests.l` does for `Web.serveTls`) so the assertions
//! exercise the real accept loop, not just `Web.dispatch`'s pure core.   Native has
//! no unwinding (D-N-003), so a handler panic ends that process and this
//! suite is for dotnet and the JVM.
//!
//! `tests/serve_failure_tests.l` is a separate, CI-orchestrated program
//! that predates this fix (#5260); its accompanying
//! `.github/workflows/ci.yml` smoke step now asserts the post-#5261
//! contract (`/crash` → 500, failure line logged, `/health` still 200,
//! then `kill`), updated alongside this fix (#6218). See that file's
//! header for the full CI-step description.
@test_module
package Web.ServeCrashIsolationTests

import Std.Core
import Std.Http
import Std.HttpServerHost
import Std.Time as Time
import Web
import Std.Testing

record HealthHandler {
}

impl Web.Handler for HealthHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, "ok")
  }
}

record CrashHandler {
}

impl Web.Handler for CrashHandler {
  func handle(req: in Web.Request): Web.Response {
    panic("intentional crash for the serve() crash-isolation test")
  }
}

func crashRouter(): Web.Router {
  var r = Web.create()
  r = Web.addGet(r, "/health", HealthHandler())
  r = Web.addGet(r, "/crash", CrashHandler())
  r
}

// `Web.serve` blocks the calling thread forever once bound, so the server runs
// on a background thread from the `Std.HttpServerHost` seam (a thread-pool
// task on dotnet, a virtual thread on the JVM, a thread on native): the real
// concurrency `spawn` cannot give on dotnet (D119/D120).  One helper for every
// target; docs/73 S6 retired the per-target ones.
func startServerForTest(r: in Web.Router, port: in Int): Unit {
  startTask({ -> Web.serve(r, "127.0.0.1", port) })
}

// Retry a GET against `url` until the listener accepts the connection (it
// binds asynchronously on the background task) or the attempt budget is
// exhausted — mirrors `serve_tls_tests.l`'s `serveAndGet` polling shape.
// A connection error (not yet listening) is retried; the first response
// ends the loop.  An exhausted budget returns `(0, "")`.
func pollGet(client: in HttpClient, url: in String, maxAttempts: in Int): (Int, String) {
  var attempt = 0
  var status = 0
  var body = ""
  var done = false
  while attempt < maxAttempts and not done {
    Time.sleepMillis(50)
    match await client.get(url) {
      case Ok(resp) -> {
        status = HttpResponse.statusCode(resp)
        body = match await HttpResponse.bodyText(resp) { case Ok(b) -> b; case Err(_) -> "" }
        done = true
      }
      case Err(_) -> {
        attempt = attempt + 1
      }
    }
  }
  return (status, body)
}

test "a handler panic is isolated to that request: serve() answers 500 and keeps serving" {
  val port = 18940
  val client = HttpClientBuilder.build(HttpClientBuilder.new())
  startServerForTest(crashRouter(), port)

  val healthUrl = "http://127.0.0.1:" + port.toString() + "/health"
  val crashUrl = "http://127.0.0.1:" + port.toString() + "/crash"

  val (healthStatus, healthBody) = pollGet(client, healthUrl, 40)
  assertEqualInt(healthStatus, 200, "server is up before the crash")

  match await client.get(crashUrl) {
    case Ok(resp) -> assertEqualInt(
      HttpResponse.statusCode(resp),
      500,
      "a panicking handler answers 500, not a dropped connection"
    )
    case Err(_) -> assertTrue(false, "handler panic broke the connection instead of answering 500 (#5261)")
  }

  match await client.get(healthUrl) {
    case Ok(resp) -> assertEqualInt(
      HttpResponse.statusCode(resp),
      200,
      "the server kept serving after the panic (#5261)"
    )
    case Err(_) -> assertTrue(false, "server stopped serving after a single request's handler panic (#5261)")
  }
}
