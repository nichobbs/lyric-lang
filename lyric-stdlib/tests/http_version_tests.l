//! stdlib/tests/http_version_tests.l — deterministic coverage for the
//! `HttpVersion` builder knob (docs/61 §5.1, D128 decision 4; #5879).
//!
//! Coverage model: everything here dispatches WITHOUT a live listener and
//! WITHOUT ever touching the network, same discipline as
//! `http_async_tests.l`'s dead-port fixture but stronger — `Http3` is
//! refused entirely inside `Std.Http` before any kernel call is made
//! (`HttpClientImpl.unsupportedReason`), so its `ConnectionFailed` is fully
//! deterministic (no dependence on a real connection failing a particular
//! way) and asserted here against every `HttpClient` trait method plus
//! combined with the redirect-following knobs, to confirm the guard is
//! independent of transport configuration. (A Unix-socket + `Http3` combo
//! is not exercised here: constructing a Unix-socket client is unsupported
//! on the JVM target regardless of HTTP version — pre-existing, tracked
//! in #2663 — so `build()` itself panics there before the `Http3` gate
//! would ever run; that is a target limitation of Unix sockets, not of
//! this feature.)
//!
//! What this file deliberately does NOT try to prove: that a `Http2`- or
//! `Http11`-configured client does NOT take the `Http3` short-circuit.
//! Proving that deterministically without a live listener would mean
//! asserting on the CONTENT of a real connection-refused error message,
//! which is host/OS/JDK-dependent and too fragile to pin here. That
//! property is instead proven — more directly — by the real round-trip
//! tests below, which get an actual 200 OK back through default/`Http2`/
//! `Http11`-configured clients; if `unsupportedReason` were set for any of
//! those, the round trip would fail with `ConnectionFailed` instead of
//! succeeding:
//!   * `lyric-compiler/lyric/http_version_self_test.l` (dotnet, child-process
//!     listener harness, mirrors `http_roundtrip_self_test.l`) — asserts the
//!     default client's `negotiatedVersion()` is `Http11` over plaintext
//!     (h2 only upgrades via ALPN/TLS) and that `withHttpVersion(Http11)`
//!     pins it explicitly too.
//!   * `lyric-compiler/lyric/http_version_jvm_self_test.l` (jvm, in-process
//!     `scope`/`spawn` — genuinely concurrent on this target, D120) — same
//!     two assertions.
//!
//! NOT yet wired into CI — the orchestrator should add it alongside
//! `http_async_tests.l` (both targets; see that file's own header note).
@test_module
package Std.Http.VersionTests

import Std.Core
import Std.Errors
import Std.Http
import Std.String
import Std.Task
import Std.Testing

// Port 1 is in the reserved range and never has a listener; connecting to
// it fails fast without leaving the sandbox (same fingerprint as
// http_async_tests.l). Used only for the "URL validation happens first"
// check below, which never depends on the failure's message content.
val deadUrl: String = "http://127.0.0.1:1/"

val http3Marker: String = "HTTP/3"

// Unwraps `Err(e)` first, then matches `e`'s HttpError cases in a SEPARATE,
// top-level `match` — deliberately not `case Err(ConnectionFailed(_, m)) ->
// ...` (D-progress-688 / #5903): matching a union case nested directly
// inside another case's payload does not reliably discriminate on the
// self-hosted JVM backend today (confirmed while writing this file — see
// `HttpClientBuilder.build()`'s own `version`/`pinHttp11` two-step match for
// the fix that motivated this same shape here).
func expectHttp3Unsupported(r: in Result[HttpResponse, HttpError], label: in String): Unit {
  match r {
    case Ok(_) -> panic(label + ": expected the Http3-unsupported error")
    case Err(e) -> match e {
      case ConnectionFailed(_, message) ->
        assertTrue(contains(message, http3Marker), label + ": message should name HTTP/3, got: " + message)
      case other -> panic(label + ": expected ConnectionFailed, got a different HttpError case")
    }
  }
}

// ─── Http3 gates every HttpClient trait method deterministically ────────────
test "Http3 gates get/post/put/delete/patch deterministically" {
  val c = HttpClientBuilder.build(HttpClientBuilder.new().withHttpVersion(Http3))
  expectHttp3Unsupported(await c.get(deadUrl), "Http3 get")
  expectHttp3Unsupported(await c.post(deadUrl, "body"), "Http3 post")
  expectHttp3Unsupported(await c.put(deadUrl, "body"), "Http3 put")
  expectHttp3Unsupported(await c.delete(deadUrl), "Http3 delete")
  expectHttp3Unsupported(await c.patch(deadUrl, "body"), "Http3 patch")
}

test "Http3 gates HttpClient.send and sendWithCancel" {
  val url = match Url.tryFrom(deadUrl) {
    case Ok(u) -> u
    case Err(e) -> panic("Url.tryFrom failed unexpectedly")
  }
  val c = HttpClientBuilder.build(HttpClientBuilder.new().withHttpVersion(Http3))
  expectHttp3Unsupported(await c.send(request(GET, url)), "Http3 send")
  val src = makeCancelSource()
  expectHttp3Unsupported(await c.sendWithCancel(request(GET, url), sourceToken(src)), "Http3 sendWithCancel")
  disposeSource(src)
}

test "Http3 still validates URLs before the version gate" {
  val c = HttpClientBuilder.build(HttpClientBuilder.new().withHttpVersion(Http3))
  match await c.get("not-a-url") {
    case Ok(_) -> panic("expected InvalidUrl for a scheme-less string")
    case Err(e) -> match e {
      case InvalidUrl(_) -> ()
      case other -> panic("expected InvalidUrl even with Http3 configured")
    }
  }
}

// ─── Http3 gate is independent of the other builder knobs ───────────────────
test "Http3 gates regardless of redirect configuration" {
  val withRedirects = HttpClientBuilder.build(
    HttpClientBuilder.new().withRedirects(3).withHttpVersion(Http3)
  )
  expectHttp3Unsupported(await withRedirects.get(deadUrl), "Http3 + withRedirects")

  val withNoRedirects = HttpClientBuilder.build(
    HttpClientBuilder.new().withNoRedirects().withHttpVersion(Http3)
  )
  expectHttp3Unsupported(await withNoRedirects.get(deadUrl), "Http3 + withNoRedirects")
}
