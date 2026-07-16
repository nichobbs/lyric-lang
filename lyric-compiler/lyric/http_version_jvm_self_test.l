//! http_version_jvm_self_test.l — real HTTP round trips proving the
//! `HttpVersion` client default/pin (docs/61 §5.1, D128 decision 4; #5879)
//! against a live PLAINTEXT `Std.HttpServer` listener, on the JVM target.
//!
//! Why this needs its own file instead of sharing one with the dotnet round
//! trip (`http_version_self_test.l`): both need a listener and a client
//! running CONCURRENTLY in one process, and the two targets get there by
//! different, incompatible mechanisms.
//!
//!   * On `--target jvm`, `scope { }` / `spawn e` / `await t` (D119/D120)
//!     lower to a REAL virtual-thread `ExecutorService` (`async_spawn_self_test.l`
//!     is the load-bearing proof of this) — a spawned task and the scope
//!     body genuinely run concurrently, so a spawned "pull one request, respond"
//!     task can unblock a synchronous client call issued right after it in the
//!     same scope. That is exactly the shape used below.
//!   * On `--target dotnet`, the same keywords still lower to the
//!     degenerate-synchronous form (MSIL real structured concurrency is
//!     D119 S5/S6, not yet shipped): `spawn e` runs `e` inline, so a spawned
//!     blocking accept-loop would run to completion (i.e. hang forever
//!     waiting for a request that hasn't been sent yet) before control ever
//!     reached the client call. `http_version_self_test.l` uses a real OS
//!     child process instead (mirrors `http_roundtrip_self_test.l`), for the
//!     same underlying reason `http_roundtrip_self_test.l`'s own header
//!     documents (#5329).
//!
//! Coverage: plaintext responses are ALWAYS `Http11` — h2 only upgrades via
//! ALPN, which requires TLS, so there is no server-side TLS coverage needed
//! to pin this property (`Std.HttpServer` has no TLS surface yet; server TLS
//! is phase 2/3 of docs/61, tracked separately). Two cases:
//!   1. the default client's `negotiatedVersion()` is `Http11` over
//!      plaintext, even though the client's own default is now h2-or-lower
//!      (D128 decision 3/4) — proves the default change is behavior-safe;
//!   2. `withHttpVersion(Http11)` also reports `Http11` (the redundant-but-
//!      exercised exact pin).
//!
//! Run in CI via native `lyric test --target jvm` (like `bitwise_self_test.l`
//! / `async_spawn_self_test.l`). Imports only `Std.*`, so no
//! `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.HttpVersionJvmSelfTest

import Std.Core
import Std.Errors
import Std.Http
import Std.HttpServer as Server
import Std.Testing

func versionName(v: in HttpVersion): String {
  match v {
    case Http11 -> "Http11"
    case Http2 -> "Http2"
    case Http3 -> "Http3"
  }
}

// Answers exactly one request with a fixed 200 OK body. Run as a spawned
// task alongside a single client call in the same scope (module header).
async func respondOnce(l: in Server.HttpListener): Unit {
  val ctx = Server.nextContext(l)
  Server.respondText(ctx, 200, "pong")
}

test "default client negotiatedVersion is Http11 over plaintext" {
  val l = Server.startListener("http://127.0.0.1:18234/")
  scope {
    val serverTask = spawn respondOnce(l)
    val result = await getAsync("http://127.0.0.1:18234/ping")
    match result {
      case Err(e) -> panic("GET failed: " + HttpError.message(e))
      case Ok(response) -> {
        assertEqualInt(response.statusCode(), 200, "status is 200")
        assertEqual(versionName(response.negotiatedVersion()), "Http11", "plaintext default stays Http11")
      }
    }
    await serverTask
  }
  Server.stopListener(l)
}

test "withHttpVersion(Http11) pins negotiatedVersion to Http11 over plaintext" {
  val l = Server.startListener("http://127.0.0.1:18235/")
  val client = HttpClientBuilder.build(HttpClientBuilder.new().withHttpVersion(Http11))
  scope {
    val serverTask = spawn respondOnce(l)
    val result = await client.get("http://127.0.0.1:18235/ping")
    match result {
      case Err(e) -> panic("GET failed: " + HttpError.message(e))
      case Ok(response) -> {
        assertEqualInt(response.statusCode(), 200, "status is 200")
        assertEqual(versionName(response.negotiatedVersion()), "Http11", "explicit Http11 pin holds over plaintext")
      }
    }
    await serverTask
  }
  Server.stopListener(l)
}
