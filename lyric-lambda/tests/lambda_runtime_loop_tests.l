//! tests/lambda_runtime_loop_tests.l — mock Runtime API server exercising
//! `Lambda.Dispatch`'s real HTTP transport (`pollAndDispatchOnce`) end to
//! end over a live loopback connection: a synthetic event is served from
//! the mock's `GET .../invocation/next` endpoint, and the dispatch loop's
//! `POST .../invocation/{id}/response` (or `/error`) is captured and
//! asserted — the concrete "local mock-server test" that `lambda_tests.l`
//! and `lambda_dispatch_tests.l` (deliberately pure / no I/O) leave open,
//! and the gap PR #5135 investigated and found no server-lifecycle test
//! infra existed anywhere in the repo to build this on.
//!
//! ## Why this only runs on `--target jvm`, and why it is NOT registered in
//! `[project.tests]`
//!
//! Running a mock HTTP server and a client dispatch loop against it in the
//! same process needs two genuinely concurrent pieces of work: one to
//! accept connections and respond, one to poll and read them. `scope { } /
//! spawn e / await t` (D119/D120) is the only structured-concurrency
//! primitive this codebase has, but it is **only really concurrent on
//! `--target jvm`** — `spawn e` on `--target dotnet` still lowers to the
//! degenerate-synchronous form (`spawn e` runs `e` inline, `await` is the
//! identity; real MSIL structured concurrency is D119 S5/S6, not yet
//! shipped). A dotnet build/run of this file would deadlock: the spawned
//! mock server would have to run to completion (accepting and responding
//! to two requests) *before* control ever returns to spawn the client's
//! GET, but the server's first `nextContext` blocks waiting for a request
//! the client hasn't sent yet. `lambda_dispatch_tests.l`'s header
//! documents the identical blocker for `Std.Task.Scope.scopeSpawn`
//! (#5329). JVM's virtual-thread `ExecutorService` codegen
//! (`jvm/codegen/05_stmts.l`) has no such restriction — verified by
//! `async_spawn_self_test.l`.
//!
//! A file-level `@cfg(feature = "jvm")` looked like the natural way to
//! keep this out of CI's dotnet-only default `lyric test --manifest
//! lyric-lambda/lyric.toml` / `--features local` invocations (which would
//! otherwise hang on the deadlock above) — it was tried and reverted: it
//! compiles clean but crashes at runtime with `System.
//! MissingMethodException: Entry point not found` once `web`/`jvm` is
//! inactive, because `Lyric.TestSynth` synthesises `main()`'s test calls
//! *before* `@cfg` erasure runs, so a fully-erased test module ends up
//! with no entry point at all rather than a clean "0 tests" pass. Filed
//! as #6868 (see that issue for the isolated repro). Until it's fixed,
//! this file is **not registered in `lyric-lambda/lyric.toml`'s
//! `[project.tests]`** — registering it would either hang every default
//! CI invocation (no `@cfg` at all) or crash it (`@cfg`-gated). It is a
//! real, complete, manually-verified test in the meantime.
//!
//! Verified manually against this exact tree: temporarily add
//! `"Lambda.RuntimeLoopTests" = "tests/lambda_runtime_loop_tests.l"` under
//! `[project.tests]` in `lyric.toml`, then:
//!   lyric test --target jvm --manifest lyric-lambda/lyric.toml --features jvm
//! Both cases passed (see this PR's description for the captured output).
@test_module
package Lambda.RuntimeLoopTests

import Std.Core
import Std.Testing
import Std.Collections
import Std.HttpServer
import Std.Encoding
import Std.Time
import Lambda
import Lambda.Direct
import Lambda.Dispatch
import Lambda.Events

// A fixed, distinct loopback port (see the other lyric-* test suites'
// fixed-port precedent, e.g. lyric-stdlib/tests/http_server_dotnet_tests.l's
// 19401-19417 range) — `Std.HttpServer.startListener` requires a nonzero
// port (no OS-assigned-ephemeral-port support), so a fixed value it is.
val mockRuntimeApiPort: Int = 19430

// ─── Fixture handlers ─────────────────────────────────────────────────────
record CaptureSqsHandler {
}

impl Lambda.SqsHandler for CaptureSqsHandler {
  func handle(event: in SqsEvent, ctx: in LambdaContext): Result[Unit, LambdaError] {
    assertEqualInt(event.records.length, 1, "mock server's SQS event has one record")
    assertEqual(
      event.records[0].body,
      "hello from the mock runtime API",
      "SQS record body decoded from the live HTTP round trip"
    )
    assertEqual(
      ctx.requestId,
      "req-mock-1",
      "LambdaContext.requestId built from the mock's Lambda-Runtime-Aws-Request-Id header"
    )
    return Ok(value = ())
  }
}

func sqsMockEventBody(): String {
  return "{\"Records\":[{\"messageId\":\"m1\",\"receiptHandle\":\"rh1\",\"body\":\"hello from the mock runtime API\"," +
    "\"attributes\":{},\"messageAttributes\":{},\"md5OfBody\":\"x\",\"eventSource\":\"aws:sqs\"," +
    "\"eventSourceARN\":\"arn:aws:sqs:us-east-1:123456789012:mock-queue\",\"awsRegion\":\"us-east-1\"}]}"
}

// ─── Mock Runtime API: exactly one GET-next then one POST-response(-or-error) ─
record MockCapturedRequest {
  path: String
  body: String
}

// Runs on a spawned virtual thread (JVM real concurrency, D120): services
// exactly the two HTTP requests one `pollAndDispatchOnce` cycle makes
// against `runtimeApi` — the GET to `.../invocation/next` (answered with
// `eventBody` plus the headers `getNextInvocation` reads) and the following
// POST to `.../invocation/{id}/response` or `/error` (captured verbatim,
// not distinguished here — the test asserts on the captured path instead).
async func mockRuntimeApiCycle(listener: in HttpListener, eventBody: in String): MockCapturedRequest {
  val nextCtx = nextContext(listener)
  val nextHeaders: Map[String, String] = newMap()
  nextHeaders.add("Lambda-Runtime-Aws-Request-Id", "req-mock-1")
  nextHeaders.add("Lambda-Runtime-Deadline-Ms", (nowEpochMillis() + 30000i64).toString())
  nextHeaders.add("Lambda-Runtime-Invoked-Function-Arn", "arn:aws:lambda:us-east-1:123456789012:function:mock-fn")
  respondBytesWithHeaders(nextCtx, 200, "application/json", encodeUtf8(eventBody), nextHeaders)

  val postCtx = nextContext(listener)
  val captured = MockCapturedRequest(path = requestPath(postCtx), body = requestBody(postCtx))
  respondText(postCtx, 202, "")
  return captured
}

record MockRunOutcome {
  dispatchOk: Bool
  dispatchErr: String
  captured: MockCapturedRequest
}

async func runOneEventThroughMockRuntimeApi(eventBody: in String, app: in LambdaApp): MockRunOutcome {
  val listener = startListener("http://localhost:" + mockRuntimeApiPort.toString() + "/")
  scope {
    val serverTask = spawn mockRuntimeApiCycle(listener, eventBody)
    val dispatchResult = pollAndDispatchOnce("localhost:" + mockRuntimeApiPort.toString(), app)
    val captured = await serverTask
    stopListener(listener)
    return match dispatchResult {
      case Ok(_) -> MockRunOutcome(dispatchOk = true, dispatchErr = "", captured = captured)
      case Err(e) -> MockRunOutcome(dispatchOk = false, dispatchErr = e, captured = captured)
    }
  }
}

// ─── Tests ────────────────────────────────────────────────────────────────
test "pollAndDispatchOnce: aws:sqs event round-trips through a live mock Runtime API server" {
  val app = Lambda.withDirect(Lambda.newApp(), Lambda.Direct.sqsHandler(CaptureSqsHandler()))
  val outcome = runOneEventThroughMockRuntimeApi(sqsMockEventBody(), app)
  assertTrue(outcome.dispatchOk, "pollAndDispatchOnce reported the transport itself as healthy: " + outcome.dispatchErr)
  assertEqual(
    outcome.captured.path,
    "/2018-06-01/runtime/invocation/req-mock-1/response",
    "posted the batch-success response to the /response endpoint, keyed by the request id captured from /next"
  )
  assertEqual(outcome.captured.body, "null", "whole-batch success response body")
}

test "pollAndDispatchOnce: a handler failure posts to the mock's /error endpoint but the transport still reports healthy" {
  // No RawDirect handler registered: dispatchInvocation returns
  // Err(InternalError(...)) for the raw catch-all, which
  // pollAndDispatchOnce posts to /error (not /response) and still returns
  // Ok(Unit) itself -- a handler-level failure is not a transport failure
  // (see pollAndDispatchOnce's own doc comment in dispatch.l).
  val app = Lambda.newApp()
  val outcome = runOneEventThroughMockRuntimeApi("{\"unrecognised\":true}", app)
  assertTrue(outcome.dispatchOk, "a handler-level failure must not surface as a transport Err: " + outcome.dispatchErr)
  assertEqual(
    outcome.captured.path,
    "/2018-06-01/runtime/invocation/req-mock-1/error",
    "posted to the /error endpoint (not /response) when no handler is registered"
  )
  assertTrue(outcome.captured.body.contains("\"errorType\":\"InternalError\""), "AWS error JSON shape posted to /error")
  assertTrue(
    outcome.captured.body.contains("no handler registered for raw"),
    "error message names the missing raw handler"
  )
}
