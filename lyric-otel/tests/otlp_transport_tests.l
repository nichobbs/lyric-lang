//! tests/otlp_transport_tests.l — env-gated live-transport test for
//! lyric-otel's OTLP/HTTP export (issue #5410).
//!
//! `otlp_codec_tests.l` covers the protobuf encoding deterministically
//! with no network. This file additionally exercises the real
//! `HttpClient`/`ByteArrayContent` kernel end-to-end against a listening
//! OTLP-shaped collector — but only when one is actually available: with
//! no collector in CI, `LYRIC_OTEL_TEST_COLLECTOR_URL` is unset and the
//! test below is a clean no-op (not a skip-vs-fail signal the runner
//! understands, just an early return that asserts nothing).
//!
//! To run it against a real (or stub) collector locally:
//!
//!   LYRIC_OTEL_TEST_COLLECTOR_URL=http://127.0.0.1:4318 \
//!     lyric test --manifest lyric-otel/lyric.toml
//!
//! This is deliberately not the in-process `Std.HttpServer` listener +
//! `scope`/`spawn` approach: on the `dotnet` target `spawn` still lowers
//! to the degenerate synchronous form (D119; real MSIL structured
//! concurrency is S5/S6, not yet shipped), so a spawned
//! `HttpListener.GetContext()` accept loop would block the single
//! calling thread before the client-side POST that's meant to unblock it
//! ever runs — a guaranteed deadlock, not a flaky test. An external
//! collector process (real or a throwaway stub) sidesteps that
//! limitation entirely via OS-level process concurrency instead of
//! in-process Lyric concurrency.
@test_module
package OTel.OtlpTransportTests

import Std.Core
import Std.Testing
import Std.Environment
import OTel
import OTel.Types
import OTel.Otlp

test "flushOtlpAsync sends real OTLP/HTTP protobuf to a live collector (env-gated)" {
  val url = getVarOrDefault("LYRIC_OTEL_TEST_COLLECTOR_URL", "")
  if url.length == 0 {
    // No collector configured for this run — nothing to assert.
    ()
  } else {
    match configureOtlpTraces(OtlpExporterConfig(endpoint = url, protocol = OtlpProtocol.HttpProtobuf, timeoutMs = 5000, headers = [])) {
      case Err(e) -> assertTrue(false, "configureOtlpTraces failed: " + e)
      case Ok(_) -> {
      }
    }
    val span = startSpan("otlp_transport_tests.live_flush", 0)
    setSpanAttribute(span, "test.attr", "value")
    endSpan(span)
    val ok = await flushOtlpAsync(5000)
    assertTrue(ok, "flushOtlpAsync reported success (2xx) against " + url)
  }
}

// A deterministic, always-on regression test for #5588: before the fix,
// `flushOtlpAsync` drained (removed) the span buffer *before* POSTing, so
// any transport failure silently lost the batch. A closed TCP port on
// localhost produces a real, fast, deterministic transport failure without
// needing a live collector (the same pattern lyric-search and lyric-db use
// for their connect-failure tests).
test "flushOtlpAsync leaves spans buffered when the export transport fails" {
  val _ = globalSpanBuffer.drain()
  match configureOtlpTraces(OtlpExporterConfig(endpoint = "http://127.0.0.1:1", protocol = OtlpProtocol.HttpProtobuf, timeoutMs = 2000, headers = [])) {
    case Err(e) -> assertTrue(false, "configureOtlpTraces failed: " + e)
    case Ok(_) -> {
    }
  }
  val span = startSpan("otlp_transport_tests.failed_flush", 0)
  endSpan(span)
  val beforeCount = globalSpanBuffer.count()
  val ok = await flushOtlpAsync(2000)
  assertFalse(ok, "flushOtlpAsync reports failure against an unreachable collector")
  assertEqualInt(
    globalSpanBuffer.count(),
    beforeCount,
    "the span is still buffered after a failed export, not silently dropped"
  )
}
