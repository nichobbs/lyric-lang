//! tests/cors_guard_tests.l — regression tests for the CORS startup guard (#353/#480).
//!
//! The `start()` function panics when Cors.enabled = true and Cors.allowedOrigins
//! is empty.  Because `start()` also binds a real HTTP port, its panic path is
//! not directly unit-testable.  `corsConfigError()` exposes the same validation
//! logic as a pure function so both branches can be exercised here.
@test_module
package Web.CorsGuardTests

import Std.Core
import Std.Testing
import Web

test "corsConfigError: enabled with empty origins returns Some(error)" {
  match corsConfigError(true, "") {
    case None -> assertTrue(false, "expected Some error for enabled + empty origins")
    case Some(msg) -> {
      assertTrue(msg.length > 0, "error message must be non-empty")
      assertTrue(msg.contains("allowedOrigins"), "error should mention allowedOrigins")
    }
  }
}

test "corsConfigError: disabled with empty origins returns None" {
  match corsConfigError(false, "") {
    case Some(msg) -> assertTrue(false, "disabled CORS should not error, got: " + msg)
    case None -> ()
  }
}

test "corsConfigError: enabled with explicit origins returns None" {
  match corsConfigError(true, "https://example.com") {
    case Some(msg) -> assertTrue(false, "valid origin list should not error, got: " + msg)
    case None -> ()
  }
}

test "corsConfigError: enabled with wildcard returns None (wildcard is warned, not rejected)" {
  match corsConfigError(true, "*") {
    case Some(msg) -> assertTrue(false, "wildcard is accepted (with warning), should not error: " + msg)
    case None -> ()
  }
}

test "corsConfigError: disabled with explicit origins returns None" {
  match corsConfigError(false, "https://example.com") {
    case Some(msg) -> assertTrue(false, "disabled CORS should not error even with origins set, got: " + msg)
    case None -> ()
  }
}
