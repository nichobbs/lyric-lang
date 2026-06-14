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
