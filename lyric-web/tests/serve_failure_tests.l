//! tests/serve_failure_tests.l — end-to-end regression pin for
//! `Web.serve()`'s failure-observability path (#5260, a review finding on
//! #5259: a caught `Bug` while handling a request now logs to stderr via
//! `Console.error` and terminates the process with `Env.exitCode(1)`,
//! instead of the request loop silently swallowing it and the process
//! eventually exiting 0 as if it had shut down cleanly).
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
//! header's last paragraph).
//!
//! Routes:
//!   GET /health  -> 200 "ok". The CI script polls this to learn when the
//!                   listener is up without ever touching the failure path.
//!   GET /crash   -> unconditionally `panic(...)`. The panic raises a `Bug`
//!                   that propagates up through `Web.dispatch` into
//!                   `Web.serve`'s request-loop `catch Bug as e` arm, which
//!                   logs `"[lyric-web] request handling failed on <prefix>:
//!                   <message>"` to stderr, stops the listener, and calls
//!                   `Env.exitCode(1)`. Driving this route is what exercises
//!                   the fix under test: the process must crash observably
//!                   (non-zero exit, message on stderr), never silently
//!                   exit 0.
//!
//! Fixed host/port (127.0.0.1:8199) rather than reading argv/env, matching
//! `examples/rest_service.l` (8080) and `tests/jvm_server_smoke.l` (8099)'s
//! precedent of a hardcoded port for a single-purpose CI smoke program;
//! 8199 avoids both of those already-claimed ports.
//!
//! CI wiring needed (not yet added — this repo's policy is that CI workflow
//! edits are called out for the session driving CI, not made inline here):
//! a step in `.github/workflows/ci.yml`, alongside "Run single-file
//! examples" (which smoke-tests `examples/rest_service.l` the same way),
//! that:
//!   1. `lyric build lyric-web/tests/serve_failure_tests.l -o <dll>`
//!   2. Runs it in the background, redirecting stdout+stderr to a log file.
//!   3. Polls `curl -s --max-time 1 -o /dev/null http://127.0.0.1:8199/health`
//!      in a bounded loop (as the existing rest_service / jvm_server_smoke
//!      steps do) until it succeeds or the process has already exited.
//!   4. `curl -s --max-time 3 http://127.0.0.1:8199/crash` (response may be
//!      truncated/reset — not asserted; the crash happens while handling it).
//!   5. `wait` on the background PID, assert the exit code is non-zero.
//!   6. Assert the log file contains `"[lyric-web] request handling failed
//!      on http://127.0.0.1:8199/: intentional crash for Web.serve() failure-path test"`.
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
