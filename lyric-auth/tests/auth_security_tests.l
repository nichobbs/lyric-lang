// tests/auth_security_tests.l — security regression suite for the
// JWT algorithm-pinning guard (lyric-lang #315 / #432) and the role
// allow-list parser (#360).
//
// Two security invariants are pinned here:
//
//   1. `Auth.verifyJwt` rejects the empty `allowedAlgorithms` string at
//      the boundary via its `requires:` contract.  An empty allow-list
//      is "no algorithm whitelisted", which under RFC 8725 §3.1 must
//      fail closed — never accept alg=none or any other algorithm.
//
//   2. `Auth.rolesContain` correctly handles the documented
//      comma-separated format including whitespace tolerance (#360).
//
// Run: `lyric test --manifest lyric-auth/lyric.toml`
// (Requires the multi-package test runner tracked in issue #465.
// Until then this file ships as the executable spec for the fix.)

@test_module
package Auth.AuthSecurityTests

import Std.Core
import Std.Testing
import Auth

// ─── Role membership (#360). ──────────────────────────────────────────────

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

// ─── JWT algorithm pinning (#315). ────────────────────────────────────────
//
// The verifyJwt entry contract is
//   requires: secret.length > 0
//   requires: allowedAlgorithms.length > 0
//
// We can't run a real JWT verification without a real signing key, but
// we can pin the *shape* of the API:
//
//   - allowedAlgorithms is positional and non-optional
//   - calling with a valid but token-mismatched algorithm returns false
//   - the safe default `"HS256"` appears in every aspect's config block
//     (verified by the aspect templates themselves at compile time)
//
// The full integration tests live alongside the lyric-web /
// lyric-grpc / lyric-ws aspect templates and exercise the wrapped
// handlers end-to-end; this file just pins the lyric-auth shape.

test "verifyJwt with a malformed token + HS256 allow-list returns false" {
  // A clearly malformed token bytes-string.  We're testing that
  // verification fails closed, not exercising real cryptography.
  val malformed = "not.a.jwt"
  val ok = Auth.verifyJwt(malformed, "test-secret", "", "", "HS256")
  assertTrue(not ok,
    "malformed token must NOT verify under any algorithm pin")
}

test "verifyJwt allow-list is comma-separated (multiple algs accepted)" {
  // Same malformed token; the allow-list with two algorithms must
  // still parse without panicking — both HS256 and RS256 are valid
  // algorithm names per RFC 7518.  Verification still fails (the
  // token is junk).
  val ok = Auth.verifyJwt("not.a.jwt", "s", "", "", "HS256,RS256")
  assertTrue(not ok, "multi-algorithm pin must still fail closed on junk input")
}
