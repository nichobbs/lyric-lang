//! tests/streaming_tests.l — end-to-end regression pin for
//! `Web.serveStreaming()`/`ResponseWriter` (lyric-lang#5979): a
//! `StreamingHandler` can send a chunk, do more work, send another chunk,
//! and the client observes the first chunk before the second is produced
//! — instead of `Web.serve()`'s buffer-the-whole-body-then-write-once
//! path, which held every byte back until the handler returned.
//!
//! **Not run via `lyric test --manifest lyric-web/lyric.toml`.** Same
//! reason as `serve_failure_tests.l`: asserting on wall-clock timing
//! between chunks of a real socket needs a real second process and a real
//! client, which a library `@test_module` (compiled and run in-process by
//! `lyric test`) cannot do. This file follows that file's precedent: a
//! plain `func main` program, built and run directly, with a CI script
//! driving it and asserting the observable behavior.
//!
//! Routes:
//!   GET /health -> 200 "ok" (Web.Handler, not streaming). The CI script
//!                  polls this to learn when the listener is up.
//!   GET /stream -> StreamingHandler. Writes "chunk0\n", sleeps 400ms,
//!                  writes "chunk1\n", never touching Web.Response at
//!                  all. Content-Type is set via `writeHeader` (exercises
//!                  the Content-Type-is-special-cased-at-commit path);
//!                  X-Stream-Test is a plain extra header (exercises the
//!                  regular-header path).
//!   GET /empty  -> StreamingHandler that returns without calling
//!                  `writeChunk` at all — `finishStream`'s
//!                  commit-if-never-committed fallback must still close a
//!                  well-formed (empty, still `Transfer-Encoding:
//!                  chunked`) response rather than hanging or erroring.
//!
//! Fixed host/port (127.0.0.1:8210) rather than reading argv/env, matching
//! `serve_failure_tests.l` (8199)'s precedent; 8210 avoids every
//! already-claimed single-file-example port.
//!
//! CI wiring: driven by the "Run single-file examples" step in
//! `.github/workflows/ci.yml`, alongside the `serve_failure_tests.l`
//! block: the step runs this program in the background via `lyric run`,
//! polls `/health`, times a `/stream` request and asserts it takes at
//! least the 400ms inter-chunk sleep (proving the bytes were not
//! buffered and released all at once), asserts both chunk markers are in
//! the body, asserts the response carries `Transfer-Encoding: chunked`
//! and no `Content-Length` (unbounded-length body, no upfront size), then
//! asserts `/empty` returns a well-formed empty chunked body.
package Web.StreamingTest

import Std.Core
import Web

extern type ThreadSleep = "System.Threading.Thread"

func sleepMs(ms: in Int): Unit {
  ThreadSleep.Sleep(ms)
}

record HealthHandler {
}

impl Web.Handler for HealthHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(200, "ok")
  }
}

record StreamHandler {
}

impl Web.StreamingHandler for StreamHandler {
  func handleStream(req: in Web.Request, w: in Web.ResponseWriter): Unit {
    Web.writeHeader(w, "Content-Type", "text/event-stream")
    Web.writeHeader(w, "X-Stream-Test", "yes")
    match Web.writeChunk(w, "chunk0\n") {
      case Ok(_) -> ()
      case Err(_) -> return
    }
    sleepMs(400)
    match Web.writeChunk(w, "chunk1\n") {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
}

record EmptyStreamHandler {
}

impl Web.StreamingHandler for EmptyStreamHandler {
  func handleStream(req: in Web.Request, w: in Web.ResponseWriter): Unit {
    ()
  }
}

func main(): Unit {
  val router = Web.addGet(Web.create(), "/health", HealthHandler())
  var streaming = Web.emptyStreamingRoutes()
  streaming = Web.addStreamingGet(streaming, "/stream", StreamHandler())
  streaming = Web.addStreamingGet(streaming, "/empty", EmptyStreamHandler())
  Web.serveStreaming(router, streaming, "127.0.0.1", 8210)
}
