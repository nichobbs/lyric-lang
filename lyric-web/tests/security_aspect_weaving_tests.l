//! tests/security_aspect_weaving_tests.l — runtime weaving tests for the
//! security-critical Web.Aspects templates.
//!
//! Unlike rate_limit_tests.l (which tests the Web.Kernel.Net.checkRateLimit
//! function directly), this module instantiates a security aspect against a
//! handler and asserts the *woven* handler actually denies/short-circuits —
//! the behaviour that protects real endpoints. A weave that silently no-ops
//! is worse than a compile error, so this is the CI guard for it.
@test_module
package Web.SecurityAspectWeavingTests

import Std.Core
import Std.Testing
import Web
import Web.Aspects

// Guard any handler named `apiKeyGuarded*` with the ApiKey template. The
// instance supplies the required `expectedKey`; the aspect compares the
// handler's `apiKey` argument against it via Auth.verifyApiKey (constant-time)
// and short-circuits with 401 on mismatch.
aspect KeyGuard from Web.Aspects.ApiKey {
  matches: name like "apiKeyGuarded*"
  config {
    expectedKey: String = "secret-key-123"
  }
}

pub func apiKeyGuardedHandler(apiKey: in String): Result[String, Web.ApiError] {
  return Ok("authorized")
}

test "ApiKey aspect: correct key proceeds to the handler" {
  match apiKeyGuardedHandler("secret-key-123") {
    case Ok(v) -> assertEqual(v, "authorized", "valid key must reach the handler")
    case Err(_) -> assertTrue(false, "valid key must not be rejected")
  }
}

test "ApiKey aspect: wrong key is denied with 401 before the handler" {
  match apiKeyGuardedHandler("wrong-key") {
    case Ok(_) -> assertTrue(false, "wrong key must be rejected before the handler runs")
    case Err(e) -> assertEqualInt(e.status, 401, "wrong key short-circuits with 401 Unauthorized")
  }
}

// Guard any handler named `authGuarded*` with the RequiresAuth template.
// We exercise the rejection path: a non-empty but invalid bearer token fails
// JWT verification, so the woven handler must short-circuit with 403 Forbidden
// without running the body. (The accept path needs a validly-signed token,
// which the signing-helper-free test harness can't produce.)
aspect AuthGuard from Web.Aspects.RequiresAuth {
  matches: name like "authGuarded*"
  config {
    jwtSecret: String = "test-signing-secret"
  }
}

pub func authGuardedHandler(authToken: in String): Result[String, Web.ApiError] {
  return Ok("authorized")
}

test "RequiresAuth aspect: an invalid token is denied with 403 before the handler" {
  match authGuardedHandler("not.a.valid.jwt") {
    case Ok(_) -> assertTrue(false, "an unverifiable token must be rejected before the handler runs")
    case Err(e) -> assertEqualInt(e.status, 403, "invalid token short-circuits with 403 Forbidden")
  }
}

// A stable HS256 token signed with the AuthGuard instance's jwtSecret
// ("test-signing-secret"), carrying no `exp` claim so it never expires. This
// lets us exercise the RequiresAuth *accept* path — a validly-signed token must
// flow through Auth.verifyJwt and reach the handler — the counterpart to the
// rejection test above. Regenerate (e.g. after a secret change) with:
//   (requires GNU coreutils' `basenc`; on macOS: `brew install coreutils`,
//   then use `gbasenc` or prefix PATH with coreutils' gnubin)
//   h=$(printf '{"alg":"HS256","typ":"JWT"}' | basenc --base64url | tr -d '=')
//   p=$(printf '{"sub":"test-user","role":"admin"}' | basenc --base64url | tr -d '=')
//   s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "test-signing-secret" -binary | basenc --base64url | tr -d '=')
//   echo "$h.$p.$s"
val validAuthToken: String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0LXVzZXIiLCJyb2xlIjoiYWRtaW4ifQ.Mj5dNtlMDypmDCnwx73ItntqJ46e90e5jSicrdDqM-s"

test "RequiresAuth aspect: a validly-signed token reaches the handler" {
  match authGuardedHandler(validAuthToken) {
    case Ok(v) -> assertEqual(v, "authorized", "a validly-signed token must reach the handler")
    case Err(_) -> assertTrue(false, "a validly-signed token must not be rejected")
  }
}

// Guard any handler named `roleGuarded*` with the RequiresRole template (enabled
// by default). A non-empty but unverifiable token must short-circuit with 403 —
// the enforcement counterpart to the RequiresAuth rejection test above.
aspect RoleGuard from Web.Aspects.RequiresRole {
  matches: name like "roleGuarded*"
  config {
    jwtSecret: String = "test-signing-secret"
    allowedRoles: String = "admin"
  }
}

pub func roleGuardedHandler(authToken: in String): Result[String, Web.ApiError] {
  return Ok("authorized")
}

test "RequiresRole aspect: an invalid token is denied with 403 before the handler" {
  match roleGuardedHandler("not.a.valid.jwt") {
    case Ok(_) -> assertTrue(false, "an unverifiable token must be rejected before the handler runs")
    case Err(e) -> assertEqualInt(e.status, 403, "invalid token short-circuits with 403 Forbidden")
  }
}

// validAuthToken carries role="admin", which matches RoleGuard's allowedRoles,
// so the woven RequiresRole must verify the signature, accept the role, and
// reach the handler — the accept counterpart to the rejection test above.
test "RequiresRole aspect: a validly-signed token with the required role reaches the handler" {
  match roleGuardedHandler(validAuthToken) {
    case Ok(v) -> assertEqual(v, "authorized", "a valid token with an allowed role must reach the handler")
    case Err(_) -> assertTrue(false, "a valid token with an allowed role must not be rejected")
  }
}

// The `enabled` master switch must bypass the guard entirely when false — a
// regression that dropped the bypass would silently start rejecting traffic on
// endpoints the operator deliberately left unguarded.
aspect KeyGuardDisabled from Web.Aspects.ApiKey {
  matches: name like "apiKeyBypassed*"
  config {
    expectedKey: String = "secret-key-123"
    enabled: Bool = false
  }
}

pub func apiKeyBypassedHandler(apiKey: in String): Result[String, Web.ApiError] {
  return Ok("reached")
}

test "ApiKey aspect: enabled=false bypasses the key check" {
  match apiKeyBypassedHandler("wrong-key") {
    case Ok(v) -> assertEqual(v, "reached", "a disabled guard must let any call through")
    case Err(_) -> assertTrue(false, "a disabled guard must not reject")
  }
}

aspect AuthGuardDisabled from Web.Aspects.RequiresAuth {
  matches: name like "authBypassed*"
  config {
    jwtSecret: String = "test-signing-secret"
    enabled: Bool = false
  }
}

pub func authBypassedHandler(authToken: in String): Result[String, Web.ApiError] {
  return Ok("reached")
}

test "RequiresAuth aspect: enabled=false bypasses JWT verification" {
  match authBypassedHandler("not.a.valid.jwt") {
    case Ok(v) -> assertEqual(v, "reached", "a disabled guard must let any call through")
    case Err(_) -> assertTrue(false, "a disabled guard must not reject")
  }
}

// Complete the bypass matrix for the remaining web aspects that carry an
// `enabled` master switch (#3653): RequiresRole, RateLimit, HttpCircuitBreaker.
// Each must short-circuit to call.proceed() when disabled.
aspect RoleGuardDisabled from Web.Aspects.RequiresRole {
  matches: name like "roleBypassed*"
  config {
    jwtSecret: String = "test-signing-secret"
    allowedRoles: String = "admin"
    enabled: Bool = false
  }
}

pub func roleBypassedHandler(authToken: in String): Result[String, Web.ApiError] {
  return Ok("reached")
}

test "RequiresRole aspect: enabled=false bypasses the role check" {
  match roleBypassedHandler("not.a.valid.jwt") {
    case Ok(v) -> assertEqual(v, "reached", "a disabled guard must let any call through")
    case Err(_) -> assertTrue(false, "a disabled guard must not reject")
  }
}

aspect RateLimitDisabled from Web.Aspects.RateLimit {
  matches: name like "rateBypassed*"
  config {
    enabled: Bool = false
  }
}

pub func rateBypassedHandler(): Result[String, Web.ApiError] {
  return Ok("reached")
}

test "RateLimit aspect: enabled=false bypasses the rate counter" {
  match rateBypassedHandler() {
    case Ok(v) -> assertEqual(v, "reached", "a disabled limiter must let any call through")
    case Err(_) -> assertTrue(false, "a disabled limiter must not reject")
  }
}

aspect CircuitBreakerDisabled from Web.Aspects.HttpCircuitBreaker {
  matches: name like "breakerBypassed*"
  config {
    enabled: Bool = false
  }
}

pub func breakerBypassedHandler(): Result[String, Web.ApiError] {
  return Ok("reached")
}

test "HttpCircuitBreaker aspect: enabled=false bypasses the circuit" {
  match breakerBypassedHandler() {
    case Ok(v) -> assertEqual(v, "reached", "a disabled breaker must let any call through")
    case Err(_) -> assertTrue(false, "a disabled breaker must not reject")
  }
}

// ─── RateLimit enforcement path ───────────────────────────────────────────────
//
// Prove that the woven RateLimit aspect actually calls the kernel and maps the
// denial to 429 — a weave that no-ops the kernel call would silently pass all
// calls through.  `requestsPerMinute=2, burstSize=1` means calls 1–3 are
// allowed (2 RPM slots + 1 burst slot) and call 4 is denied.  All four calls
// happen in rapid succession (well under one window), so the window boundary
// never flakes.
//
// Note: `webRateLimitMap` is process-global and keyed by `call.qualifiedName`.
// This test exhausts `rateLimitedHandler`'s counter (usedInWindow=3,
// burstAvailable=0) for the life of the process.  The test is designed to run
// once per process invocation; a second run in the same process would see the
// first call immediately denied (run once per CI invocation, as expected).
aspect RateEnforced from Web.Aspects.RateLimit {
  matches: name like "rateLimited*"
  config {
    requestsPerMinute: Int = 2
    burstSize: Int = 1
  }
}

pub func rateLimitedHandler(): Result[String, Web.ApiError] {
  return Ok("ok")
}

test "RateLimit aspect: call after requestsPerMinute + burstSize exhausted is denied with 429" {
  // Exhaust the RPM budget (2) and the burst budget (1): three allowed calls.
  val _ = rateLimitedHandler()
  val _ = rateLimitedHandler()
  val _ = rateLimitedHandler()
  // The fourth call must be short-circuited before the handler runs.
  match rateLimitedHandler() {
    case Ok(_) -> assertTrue(false, "an over-limit call must not reach the handler")
    case Err(e) -> assertEqualInt(e.status, 429, "over-limit call short-circuits with 429 Too Many Requests")
  }
}

// ─── HttpCircuitBreaker enforcement path ─────────────────────────────────────
//
// Prove that the woven HttpCircuitBreaker aspect opens the circuit after
// `failureThreshold` consecutive handler failures and short-circuits the next
// call with 503.  `failureThreshold=2` means two Err returns open the circuit;
// the third call must be denied without reaching the handler.  `cooldownMs` is
// set high (60 s) so the circuit stays open for the duration of the test run.
//
// Gated to `dotnet` only: `Resilience.Kernel.Jvm` stubs `circuitIsOpen` as
// always-false and `circuitRecordFailure` as a no-op, so the circuit never
// opens on JVM and the 503 assertion would fail.  JVM parity is tracked
// in #3669 (implement `Resilience.Kernel.Jvm` backed by ConcurrentHashMap).
@cfg(feature = "dotnet")
aspect BreakerEnforced from Web.Aspects.HttpCircuitBreaker {
  matches: name like "breakerLimited*"
  config {
    failureThreshold: Int = 2
    cooldownMs: Int = 60000
  }
}

// Always returns Err so the woven aspect accumulates consecutive failures.
@cfg(feature = "dotnet")
pub func breakerLimitedHandler(): Result[String, Web.ApiError] {
  return Err(Web.internalError("intentional failure for circuit-breaker test"))
}

@cfg(feature = "dotnet")
test "HttpCircuitBreaker aspect: call after failureThreshold consecutive failures is denied with 503" {
  // Drive two failures to open the circuit (failureThreshold = 2).
  val _ = breakerLimitedHandler()
  val _ = breakerLimitedHandler()
  // The circuit is now open; the next call must be short-circuited.
  match breakerLimitedHandler() {
    case Ok(_) -> assertTrue(false, "an open circuit must not reach the handler")
    case Err(e) -> assertEqualInt(e.status, 503, "open circuit short-circuits with 503 Service Unavailable")
  }
}
