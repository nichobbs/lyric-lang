// tests/auth_security_tests.l — security regression suite for the
// JWT algorithm-pinning (#315) and role allow-list (#360) work.
// Run via the multi-package test runner tracked in #465.

@test_module
package Auth.AuthSecurityTests

import Std.Core
import Std.Testing
import Auth

// Role membership (#360).

test "rolesContain matches an exact single role" {
  assertTrue(Auth.rolesContain("admin", "admin"),
    "single-element allow-list matches identical role")
}

test "rolesContain matches one role from a comma-separated list" {
  assertTrue(Auth.rolesContain("admin,manager", "manager"),
    "manager is one of [admin, manager]")
  assertTrue(Auth.rolesContain("admin,manager", "admin"),
    "admin is one of [admin, manager]")
}

test "rolesContain rejects a role not in the allow-list" {
  assertTrue(not Auth.rolesContain("admin,manager", "viewer"),
    "viewer not in [admin, manager]")
}

test "rolesContain rejects an empty role claim" {
  assertTrue(not Auth.rolesContain("admin,manager", ""),
    "empty role must not match")
}

test "rolesContain rejects against an empty allow-list" {
  assertTrue(not Auth.rolesContain("", "admin"),
    "empty allow-list must reject every role")
}

test "rolesContain trims whitespace around comma-separated entries (#360)" {
  assertTrue(Auth.rolesContain("admin, manager", "manager"),
    "leading space after comma should not break role matching")
  assertTrue(Auth.rolesContain(" admin , manager ", "admin"),
    "surrounding whitespace should be tolerated")
  assertTrue(Auth.rolesContain("admin,\tmanager", "manager"),
    "tab after comma should be tolerated")
}

test "rolesContain skips empty / whitespace-only entries" {
  assertTrue(not Auth.rolesContain("admin, ,manager", " "),
    "whitespace-only entry must not match a whitespace role")
  // Trailing comma must not create an empty match path that lets an
  // empty role claim slip through (defense-in-depth — empty role is
  // already rejected at the boundary).
  assertTrue(not Auth.rolesContain("admin,", ""),
    "trailing comma must not match empty role")
}

// JWT algorithm pinning (#315).  The empty-allow-list case is enforced
// by the `requires: allowedAlgorithms.length > 0` contract at the
// boundary — under @runtime_checked it triggers an unrecoverable panic,
// which user code cannot catch.  Tests pin only the post-contract
// invariants: that the allow-list is positional, threaded through to
// the underlying verifier, and that verification fails closed on junk
// input for both single- and multi-algorithm pins.

test "verifyJwt with a malformed token under HS256 pin returns false" {
  val ok = Auth.verifyJwt("not.a.jwt", "test-secret",
                          "issuer-x", "audience-y", "HS256")
  assertTrue(not ok, "malformed token must fail closed under HS256 pin")
}

test "verifyJwt multi-algorithm pin (HS256,RS256) still fails closed on junk" {
  val ok = Auth.verifyJwt("not.a.jwt", "test-secret",
                          "issuer-x", "audience-y", "HS256,RS256")
  assertTrue(not ok, "multi-algorithm pin must still fail closed on junk")
}
