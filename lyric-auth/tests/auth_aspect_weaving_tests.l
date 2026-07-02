//! tests/auth_aspect_weaving_tests.l — runtime weaving tests for the
//! security-critical Auth.Aspects templates.
//!
//! Unlike auth_security_tests.l (which tests Auth.verifyJwt / Auth.verifyApiKey
//! directly), this module instantiates a security aspect against a handler and
//! asserts the *woven* handler actually denies/short-circuits — the behaviour
//! that protects real call sites. A weave that silently no-ops is worse than a
//! compile error, so this is the CI guard for it.
//!
//! Mirrors the pattern in lyric-web/tests/security_aspect_weaving_tests.l.
@test_module
package Auth.AuthAspectWeavingTests

import Std.Core
import Std.Testing
import Auth.Aspects

// Guard any handler named `apiKeyGuarded*` with the ValidateKey template.
// The instance supplies the required `expectedKey`; the aspect compares the
// handler's `apiKey` argument against it via Auth.verifyApiKey (constant-time)
// and short-circuits with Err("API key is invalid") on mismatch.
aspect KeyGuard from Auth.Aspects.ValidateKey {
  matches: name like "apiKeyGuarded*"
  config {
    expectedKey: String = "secret-key-abc"
  }
}

pub func apiKeyGuardedHandler(apiKey: in String): Result[String, String] {
  return Ok("authorized")
}

test "ValidateKey aspect: correct key proceeds to the handler" {
  match apiKeyGuardedHandler("secret-key-abc") {
    case Ok(v) -> assertEqual(v, "authorized", "valid key must reach the handler")
    case Err(_) -> assertTrue(false, "valid key must not be rejected")
  }
}

test "ValidateKey aspect: wrong key is denied before the handler runs" {
  match apiKeyGuardedHandler("wrong-key") {
    case Ok(_) -> assertTrue(false, "wrong key must be rejected before the handler runs")
    case Err(e) -> assertEqual(e, "API key is invalid", "wrong key short-circuits with the error message")
  }
}

test "ValidateKey aspect: empty key is rejected with the missing-key message" {
  match apiKeyGuardedHandler("") {
    case Ok(_) -> assertTrue(false, "empty key must be rejected before the handler runs")
    case Err(e) -> assertEqual(e, "API key is missing", "empty key short-circuits with the missing-key message")
  }
}

// The `enabled` master switch must bypass the guard entirely when false — a
// regression that dropped the bypass would silently start rejecting traffic on
// call sites the operator deliberately left unguarded.
aspect KeyGuardDisabled from Auth.Aspects.ValidateKey {
  matches: name like "apiKeyBypassed*"
  config {
    expectedKey: String = "secret-key-abc"
    enabled: Bool = false
  }
}

pub func apiKeyBypassedHandler(apiKey: in String): Result[String, String] {
  return Ok("reached")
}

test "ValidateKey aspect: enabled=false bypasses the key check" {
  match apiKeyBypassedHandler("wrong-key") {
    case Ok(v) -> assertEqual(v, "reached", "a disabled guard must let any call through")
    case Err(_) -> assertTrue(false, "a disabled guard must not reject")
  }
}
