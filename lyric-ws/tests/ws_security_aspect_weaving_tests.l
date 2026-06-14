//! tests/ws_security_aspect_weaving_tests.l — runtime weaving tests for the
//! security-critical Ws.Aspects templates.
//!
//! Unlike ws_tests.l (which tests the pure Ws type surface), this module
//! instantiates security aspects against handlers and asserts the *woven*
//! handler actually denies/short-circuits — the behaviour that protects real
//! WebSocket connections. A weave that silently no-ops is worse than a compile
//! error, so this is the CI guard for it.
//!
//! Handler shape notes:
//!   WsAuth     — reads args.authToken; handler must declare `authToken: String`.
//!                Short-circuits with Err(()) (error type Unit).
//!   WsRateLimit — reads args.ctx.connectionId (nested field access); handler
//!                 must declare `ctx: WsContext`. Short-circuits with Err(()).
//!                 Rate-limit state is process-global, so each test uses a
//!                 timestamp-suffixed connectionId for a fresh counter per run.
//!
//! Mirrors the pattern in lyric-web/tests/security_aspect_weaving_tests.l.
@test_module
package Ws.WsSecurityAspectWeavingTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.Time as Time
import Ws
import Ws.Aspects

// ─── WsAuth ───────────────────────────────────────────────────────────────────
//
// Guard any handler named `wsAuthGuarded*` with the WsAuth template.
// WsAuth is C-mode (@inline_template): it reads args.authToken from the woven
// handler, so the handler must declare an `authToken: String` parameter.
// The woven return type is Result[Unit, Unit] — WsAuth short-circuits with
// Err(()) on verification failure, so the handler must return Result[Unit, Unit].
aspect WsAuthGuard from Ws.Aspects.WsAuth {
  matches: name like "wsAuthGuarded*"
  config {
    jwtSecret: String = "test-signing-secret"
  }
}

pub func wsAuthGuardedHandler(authToken: in String): Result[Unit, Unit] {
  return Ok(())
}

test "WsAuth aspect: an invalid token is denied before the handler runs" {
  match wsAuthGuardedHandler("not.a.valid.jwt") {
    case Ok(_) -> assertTrue(false, "an unverifiable token must be rejected before the handler runs")
    case Err(_) -> assertTrue(true, "invalid token short-circuits with Err(())")
  }
}

// A stable HS256 token signed with the WsAuthGuard instance's jwtSecret
// ("test-signing-secret"), carrying no `exp` claim so it never expires. This
// lets us exercise the WsAuth *accept* path — a validly-signed token must flow
// through Auth.verifyJwt and reach the handler. See #3643.
val validAuthToken: String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0LXVzZXIiLCJyb2xlIjoiYWRtaW4ifQ.Mj5dNtlMDypmDCnwx73ItntqJ46e90e5jSicrdDqM-s"

test "WsAuth aspect: a validly-signed token reaches the handler" {
  match wsAuthGuardedHandler(validAuthToken) {
    case Ok(_) -> assertTrue(true, "valid token must reach the handler")
    case Err(_) -> assertTrue(false, "valid token must not be rejected")
  }
}

// The `enabled` master switch must bypass the guard entirely when false.
aspect WsAuthGuardDisabled from Ws.Aspects.WsAuth {
  matches: name like "wsAuthBypassed*"
  config {
    jwtSecret: String = "test-signing-secret"
    enabled: Bool = false
  }
}

pub func wsAuthBypassedHandler(authToken: in String): Result[Unit, Unit] {
  return Ok(())
}

test "WsAuth aspect: enabled=false bypasses JWT verification" {
  match wsAuthBypassedHandler("not.a.valid.jwt") {
    case Ok(_) -> assertTrue(true, "a disabled guard must let any call through")
    case Err(_) -> assertTrue(false, "a disabled guard must not reject")
  }
}

// ─── WsRateLimit ─────────────────────────────────────────────────────────────
//
// Guard any handler named `wsRateLimitGuarded*` with the WsRateLimit template.
// WsRateLimit is C-mode (@inline_template): it reads args.ctx.connectionId
// (a nested field on the `ctx` argument), so the handler must declare a
// `ctx: WsContext` parameter. The woven return type is Result[Unit, Unit].
//
// Rate-limit state is stored in a process-global map keyed by
// `call.qualifiedName + ":" + args.ctx.connectionId`. Each test uses a
// connectionId suffixed with `toString(Time.nowEpochMillis())` so that
// repeated test runs in the same process receive an independent counter.
func makeWsCtx(connectionId: in String): WsContext {
  WsContext(connectionId = connectionId, path = "/ws", query = "", remoteAddress = "127.0.0.1", headers = newMap())
}

// High-limit guard: messagesPerMinute=120 so a single call in the test is
// always within the window, exercising the accept path without exhausting state.
aspect WsRateLimitGuard from Ws.Aspects.WsRateLimit {
  matches: name like "wsRateLimitGuarded*"
  config {
    messagesPerMinute: Int = 120
    burstSize: Int = 20
  }
}

pub func wsRateLimitGuardedHandler(ctx: in WsContext): Result[Unit, Unit] {
  return Ok(())
}

test "WsRateLimit aspect: a call within the limit reaches the handler" {
  val ctx = makeWsCtx("passes-" + toString(Time.nowEpochMillis()))
  match wsRateLimitGuardedHandler(ctx) {
    case Ok(_) -> assertTrue(true, "call within limit must reach the handler")
    case Err(_) -> assertTrue(false, "call within limit must not be rate-limited")
  }
}

// Tight-limit guard: messagesPerMinute=1 + burstSize=1 so the window slot and
// burst slot are exhausted after two calls; the third call must be blocked.
// A separate handler function gives this guard its own qualified-name component
// in the rate-limit key, keeping it independent of the high-limit guard above.
aspect WsRateLimitTight from Ws.Aspects.WsRateLimit {
  matches: name like "wsRateLimitTight*"
  config {
    messagesPerMinute: Int = 1
    burstSize: Int = 1
  }
}

pub func wsRateLimitTightHandler(ctx: in WsContext): Result[Unit, Unit] {
  return Ok(())
}

test "WsRateLimit aspect: calls beyond the limit and burst are blocked" {
  // Use a timestamp-based connectionId so each test run gets a fresh counter.
  val ctx = makeWsCtx("tight-" + toString(Time.nowEpochMillis()))
  // Call 1: window slot consumed → allowed.
  val r1 = wsRateLimitTightHandler(ctx)
  // Call 2: burst slot consumed → allowed.
  val r2 = wsRateLimitTightHandler(ctx)
  // Call 3: both window and burst exhausted → blocked.
  val r3 = wsRateLimitTightHandler(ctx)
  val r1Ok = match r1 { case Ok(_) -> true; case Err(_) -> false }
  val r3Ok = match r3 { case Ok(_) -> true; case Err(_) -> false }
  assertTrue(r1Ok, "first call must proceed (within limit)")
  assertTrue(not r3Ok, "third call must be blocked (limit and burst exhausted)")
}

// The `enabled` master switch must bypass the rate counter entirely when false.
aspect WsRateLimitDisabled from Ws.Aspects.WsRateLimit {
  matches: name like "wsRateLimitBypassed*"
  config {
    enabled: Bool = false
  }
}

pub func wsRateLimitBypassedHandler(ctx: in WsContext): Result[Unit, Unit] {
  return Ok(())
}

test "WsRateLimit aspect: enabled=false bypasses the rate counter" {
  val ctx = makeWsCtx("disabled-" + toString(Time.nowEpochMillis()))
  match wsRateLimitBypassedHandler(ctx) {
    case Ok(_) -> assertTrue(true, "a disabled limiter must let any call through")
    case Err(_) -> assertTrue(false, "a disabled limiter must not reject")
  }
}
