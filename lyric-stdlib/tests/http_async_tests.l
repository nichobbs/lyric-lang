//! stdlib/tests/http_async_tests.l — runtime tests for Std.Http's async
//! client surface reached through the `HttpClient` INTERFACE (#5564).
//!
//! Before the fix, `Lyric.Stdlib.dll`'s interfaces got a TypeRef but never
//! any method MemberRefs on the consumer side
//! (`registerStdlibTypeItemMembers` skipped `IInterface`), so EVERY call
//! through the `HttpClient` interface (`defaultClient().get(...)`,
//! `.post(...)`, `.send(...)`, ...) threw "unsupported method ... on the
//! receiver type" at run time BEFORE any connection was attempted — the
//! whole client-object surface of Std.Http was unreachable from user code.
//!
//! Coverage model:
//!   * Every test dispatches through the interface at run time and asserts
//!     a typed `Result` comes back.  The calls target port 1 (reserved,
//!     never assignable), so the connection fails fast and deterministically
//!     with `Err(ConnectionFailed ...)` — which is sufficient to pin the
//!     regression, because the pre-fix failure threw before connecting.
//!   * A LIVE `Std.HttpServer` round trip through the interface is not
//!     expressible in a single-threaded stdlib test today: the impl-method
//!     bodies resolve their kernel awaits synchronously (an `async func`
//!     kickoff completes before returning on `--target dotnet`), `spawn`
//!     is degenerate-synchronous on MSIL, and `Std.Task.scopeSpawn` never
//!     invokes its closure (#5329) — so the client call and the blocking
//!     `Server.nextContext` accept loop cannot overlap in one process.
//!     The live Ok-path for the SAME kernel/impl bodies is covered by
//!     `lyric-compiler/lyric/http_roundtrip_self_test.l` (child-process
//!     listener harness); free `getAsync` / `HttpClientImpl.get` differ
//!     only in dispatch, which is exactly what THIS file exercises.
//!
//! NOT yet wired into CI — the orchestrator should add it alongside the
//! other `lyric-stdlib/tests/*_tests.l` steps (dotnet target).
@test_module
package Std.Http.AsyncTests

import Std.Core
import Std.Errors
import Std.Http
import Std.Testing

// Port 1 is in the reserved range and never has a listener; connecting to
// it fails fast without leaving the sandbox.
val deadUrl: String = "http://127.0.0.1:1/"

func expectConnectionErr(r: in Result[HttpResponse, HttpError], label: in String): Unit {
  match r {
    case Ok(_) -> panic(label + ": expected a connection error against port 1")
    case Err(ConnectionFailed(_, _)) -> ()
    case Err(other) -> panic(label + ": expected ConnectionFailed, got: " + HttpError.message(other))
  }
}

// ─── HttpClient interface dispatch (#5564) ───────────────────────────────────
test "#5564: defaultClient().get dispatches and surfaces a typed error" {
  val c = defaultClient()
  expectConnectionErr(await c.get(deadUrl), "defaultClient().get")
}

test "#5564: dispatch through an interface-typed binding" {
  val c: HttpClient = defaultClient()
  expectConnectionErr(await c.post(deadUrl, "body"), "c.post")
  expectConnectionErr(await c.put(deadUrl, "body"), "c.put")
  expectConnectionErr(await c.delete(deadUrl), "c.delete")
  expectConnectionErr(await c.patch(deadUrl, "body"), "c.patch")
}

test "#5564: HttpClient.send dispatches a built request" {
  val url = match Url.tryFrom(deadUrl) {
    case Ok(u) -> u
    case Err(e) -> panic("Url.tryFrom failed: " + HttpError.message(e))
  }
  val c = defaultClient()
  expectConnectionErr(await c.send(request(GET, url)), "c.send")
  expectConnectionErr(await c.send(withTextBody(request(POST, url), "payload")), "c.send POST")
}

test "#5564: interface dispatch through builder-constructed clients" {
  val viaBuilder = HttpClientBuilder.build(HttpClientBuilder.new())
  expectConnectionErr(await viaBuilder.get(deadUrl), "builder client .get")
  val noRedirects = clientNoRedirects()
  expectConnectionErr(await noRedirects.get(deadUrl), "clientNoRedirects().get")
}

test "#5564: interface dispatch still validates URLs before connecting" {
  val c: HttpClient = defaultClient()
  match await c.get("not-a-url") {
    case Ok(_) -> panic("expected InvalidUrl for a scheme-less string")
    case Err(InvalidUrl(_)) -> ()
    case Err(other) -> panic("expected InvalidUrl, got: " + HttpError.message(other))
  }
}

test "#5564: interface-dispatched call result flows through Result combinators" {
  val c = defaultClient()
  val ok = match await c.get(deadUrl) { case Ok(_) -> false; case Err(_) -> true }
  assertTrue(ok, "interface-dispatched Result matches through both arms")
}
