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

// ─── parseServerPort (#C-WEB-1) ───────────────────────────────────────────────
test "parseServerPort: default 8080 parses" {
  match Web.parseServerPort("8080") {
    case Ok(p) -> assertEqualInt(p, 8080, "8080 parses")
    case Err(e) -> assertTrue(false, "8080 should parse: " + e)
  }
}

test "parseServerPort: a configured port is honoured (not silently ignored)" {
  match Web.parseServerPort("3000") {
    case Ok(p) -> assertEqualInt(p, 3000, "3000 parses to 3000")
    case Err(e) -> assertTrue(false, "3000 should parse: " + e)
  }
}

test "parseServerPort: lower bound 1 is accepted" {
  match Web.parseServerPort("1") {
    case Ok(p) -> assertEqualInt(p, 1, "port 1 is the inclusive lower bound")
    case Err(e) -> assertTrue(false, "port 1 should parse: " + e)
  }
}

test "parseServerPort: upper bound 65535 is accepted" {
  match Web.parseServerPort("65535") {
    case Ok(p) -> assertEqualInt(p, 65535, "port 65535 is the inclusive upper bound")
    case Err(e) -> assertTrue(false, "port 65535 should parse: " + e)
  }
}

test "parseServerPort: 65536 (one past the upper bound) is rejected" {
  match Web.parseServerPort("65536") {
    case Ok(p) -> assertTrue(false, "65536 is one past the upper bound, should error")
    case Err(_) -> ()
  }
}

test "parseServerPort: out-of-range port is rejected" {
  match Web.parseServerPort("70000") {
    case Ok(p) -> assertTrue(false, "70000 is out of range, should error")
    case Err(_) -> ()
  }
}

test "parseServerPort: zero is rejected" {
  match Web.parseServerPort("0") {
    case Ok(p) -> assertTrue(false, "port 0 should error")
    case Err(_) -> ()
  }
}

test "parseServerPort: non-numeric is rejected" {
  match Web.parseServerPort("abc") {
    case Ok(p) -> assertTrue(false, "non-numeric should error")
    case Err(_) -> ()
  }
}

// ─── parseCorsMaxAge ──────────────────────────────────────────────────────────
test "parseCorsMaxAge: a configured value is honoured" {
  assertEqualInt(Web.parseCorsMaxAge("3600", 86400), 3600, "3600 parses")
}

test "parseCorsMaxAge: malformed falls back to default" {
  assertEqualInt(Web.parseCorsMaxAge("nope", 86400), 86400, "malformed -> default")
}

test "parseCorsMaxAge: negative falls back to default" {
  assertEqualInt(Web.parseCorsMaxAge("-5", 86400), 86400, "negative -> default")
}
