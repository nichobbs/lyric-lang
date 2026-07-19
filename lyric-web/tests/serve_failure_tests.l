//! tests/serve_failure_tests.l — end-to-end regression pin for
//! `Web.serve()`'s failure-observability path (#5260, a review finding on
//! #5259: a caught `Bug` while handling a request logs to stderr via
//! `Console.error` instead of the request loop silently swallowing it and
//! the process eventually exiting 0 as if it had shut down cleanly).
//!
//! **Historical note (#5261):** at the time this file was written, ANY
//! `Bug` while handling a request — including a plain handler panic, as
//! `/crash` below raises — stopped the listener and terminated the whole
//! process with `Env.exitCode(1)`. #5261 (a review finding on #5259)
//! flagged that as not production-grade: a single bad request must not
//! take the whole server down. `Web.serve`/`Web.serveStreaming` now
//! isolate a per-request `Bug` (handler panic, malformed request, broken
//! connection) to that request — it is logged and answered with a 500,
//! and the accept loop keeps serving. Only a `nextContext` failure (the
//! listener itself can no longer accept connections) is still fatal.
//! `tests/serve_crash_isolation_tests.l` is the `[project.tests]`-run
//! regression pin for that corrected contract (a real `Web.serve`
//! listener, driven in-process: a `/crash` hit answers 500 and a
//! following `/health` hit still succeeds).
//!
//! This file's OWN `/crash` route therefore no longer crashes the process
//! it used to pin — hitting it now logs the failure line below and
//! answers 500, and this program keeps running afterward. The
//! `.github/workflows/ci.yml` "smoke lyric-web/tests/serve_failure_tests.l"
//! step asserts this new contract (updated alongside the #5261 fix, #6218):
//! poll `/health` for readiness, assert `/crash` returns 500, assert the
//! failure line is logged, assert `/health` still returns 200 (proving the
//! server survived the panic), then `kill` the process — it no longer exits
//! on its own.
//!
//! **Not run via `lyric test --manifest lyric-web/lyric.toml`.** Unlike the
//! `[project.tests]` entries in this directory (`dispatch_tests.l`,
//! `cors_guard_tests.l`, …), asserting on a *second process's* exit code and
//! stderr needs real process-level orchestration that a library
//! `@test_module` — compiled and run in-process by `lyric test` — cannot
//! do. `lyric-compiler/lyric/http_roundtrip_self_test.l` gets around this by
//! importing `Lyric.Emitter` to compile a throwaway child-server program at
//! runtime and launching it with `Std.ProcessHost`, but `Lyric.Emitter` is a
//! compiler-internal package reserved for the self-hosted compiler tree
//! (see CLAUDE.md) — not available to an ecosystem library's own tests.
//! This file instead follows `tests/jvm_server_smoke.l`'s precedent: a plain
//! `func main` program, built and run directly, with a CI script driving it
//! and asserting the observable behavior (see the CI step named in this
//! header's last paragraph — pinning the post-#5261 crash-isolation
//! contract, see above).
//!
//! Routes:
//!   GET /health  -> 200 "ok". The CI script polls this to learn when the
//!                   listener is up without ever touching the failure path.
//!   GET /crash   -> unconditionally `panic(...)`. The panic raises a `Bug`
//!                   that propagates up through `Web.dispatch` into
//!                   `Web.serveStreaming`'s per-request `catch Bug as e` arm
//!                   (`Web.serve` delegates there, #5990), which logs
//!                   `"[lyric-web] request handling failed on <prefix>:
//!                   <message>"` to stderr and answers 500 for this request
//!                   only — the process keeps running and keeps serving
//!                   `/health` afterward (#5261).
//!
//! Fixed host/port (127.0.0.1:8199) rather than reading argv/env, matching
//! `examples/rest_service.l` (8080) and `tests/jvm_server_smoke.l` (8099)'s
//! precedent of a hardcoded port for a single-purpose CI smoke program;
//! 8199 avoids both of those already-claimed ports.
//!
//! CI wiring: driven by the "Run single-file examples" step in
//! `.github/workflows/ci.yml` (the `=== smoke
//! lyric-web/tests/serve_failure_tests.l ===` block beside the
//! `examples/rest_service.l` smoke).
package Web.ServeFailureTest

import Std.Core
import Web

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
    panic("intentional crash for Web.serve() failure-path test")
  }
}

func main(): Unit {
  var router = Web.create()
  router = Web.addGet(router, "/health", HealthHandler())
  router = Web.addGet(router, "/crash", CrashHandler())
  Web.serve(router, "127.0.0.1", 8199)
}
