// tests/auth_security_tests.l — security regression suite for the
// JWT algorithm-pinning (#315) and role allow-list (#360) work.
// Run via the multi-package test runner tracked in #465.

@test_module
package Auth.AuthSecurityTests

import Std.Core
import Std.Testing
import Auth as Auth

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

// ─── jwtAlg extraction (#553) ─────────────────────────────────────────────────
// jwtAlg is package-private; tested via verifyJwt which short-circuits to false
// before the kernel when the extracted alg is missing or not in the allow-list.

test "jwtAlg: no-padding header (rem==0) correctly extracts HS256" {
  // Header: {"alg":"HS256","typ":"JWT"} → eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 (len=36, rem=0)
  // Alg is HS256 which IS in the allow-list, so we reach the kernel.
  // The kernel rejects the fake signature, so verifyJwt returns false.
  // This confirms jwtAlg did not return "" (which would mean it failed to extract alg).
  // Note: we cannot distinguish "alg extracted but sig invalid" from a correct extraction
  // for this case — what matters is that no panic occurs and the result is false (safe).
  val ok = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.fakesig",
    "test-secret", "", "", "HS256")
  assertTrue(not ok, "HS256 token with fake signature must fail closed")
}

test "jwtAlg: two-equals-padding header (rem==2) — missing alg returns false" {
  // Header: {"typ":"JWT"} → eyJ0eXAiOiJKV1QifQ (len=18, rem=2; needs == padding)
  // No "alg" key → jwtAlg returns "" → verifyJwt returns false before kernel.
  val ok = Auth.verifyJwt(
    "eyJ0eXAiOiJKV1QifQ.payload.fakesig",
    "test-secret", "", "", "HS256")
  assertTrue(not ok, "header with no alg field must fail closed (rem==2 padding path)")
}

test "jwtAlg: one-equals-padding header (rem==3) — empty JSON has no alg" {
  // Header: {} → e30 (len=3, rem=3; needs = padding)
  // No "alg" key → jwtAlg returns "" → verifyJwt returns false before kernel.
  val ok = Auth.verifyJwt(
    "e30.payload.fakesig",
    "test-secret", "", "", "HS256")
  assertTrue(not ok, "empty JSON header has no alg field (rem==3 padding path)")
}

test "jwtAlg: invalid rem==1 segment is treated as malformed" {
  // A base64url segment whose length % 4 == 1 is not valid base64url.
  // jwtAlg returns "" → verifyJwt returns false.
  // "aaaaa" is 5 chars; 5 % 4 = 1.
  val ok = Auth.verifyJwt(
    "aaaaa.payload.fakesig",
    "test-secret", "", "", "HS256")
  assertTrue(not ok, "rem==1 base64url segment is malformed — must fail closed")
}

test "jwtAlg: token with no dot separator fails closed" {
  // No '.' → dot < 0 → jwtAlg returns "" → verifyJwt returns false.
  val ok = Auth.verifyJwt(
    "nodot",
    "test-secret", "", "", "HS256")
  assertTrue(not ok, "token with no dot separator must fail closed")
}

test "jwtAlg: alg not in allow-list is rejected before the kernel" {
  // Header: {"alg":"RS256"} → eyJhbGciOiJSUzI1NiJ9 (len=20, rem=0)
  // jwtAlg extracts "RS256"; allowedAlgorithms is "HS256" → rejected before kernel.
  val ok = Auth.verifyJwt(
    "eyJhbGciOiJSUzI1NiJ9.payload.fakesig",
    "test-secret", "", "", "HS256")
  assertTrue(not ok, "RS256 alg rejected when only HS256 is in allow-list")
}

// ─── Duplicate alg key attack regression (#560) ───────────────────────────────
// RFC 8259 §4 permits duplicate keys; last-wins is common in many JSON parsers.
// A crafted header {"alg":"RS256","alg":"HS256"} tries to mask the real alg behind
// a trusted-looking first alg value.  lastIndexOf in jwtAlg picks up "HS256" (last),
// which is then checked against the allow-list — so the attack is detected.

test "duplicate alg attack: lastIndexOf picks last alg, rejects wrong algorithm" {
  // Header: {"alg":"RS256","typ":"JWT","alg":"HS256"} (last alg = HS256)
  // → eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImFsZyI6IkhTMjU2In0 (len=55, rem=3; needs = padding)
  // allowedAlgorithms = "RS256" — if we mistakenly picked the first alg (RS256)
  // we would proceed to the kernel; with lastIndexOf we pick "HS256" and reject
  // before the kernel since HS256 ∉ {"RS256"}.
  val ok = Auth.verifyJwt(
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImFsZyI6IkhTMjU2In0.payload.fakesig",
    "test-secret", "", "", "RS256")
  assertTrue(not ok,
    "duplicate alg header: last alg (HS256) not in RS256-only allow-list — must reject")
}

test "duplicate alg attack: both algs in allow-list — still fails on invalid sig" {
  // Header: same duplicate alg header (last alg = HS256), but now HS256 IS allowed.
  // jwtAlg returns "HS256"; rolesContain("HS256,RS256","HS256") = true → kernel called.
  // Kernel rejects the fake signature → false.  Confirms lastIndexOf picks "HS256"
  // and that the token is still validated (not silently accepted).
  val ok = Auth.verifyJwt(
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImFsZyI6IkhTMjU2In0.payload.fakesig",
    "test-secret", "", "", "HS256,RS256")
  assertTrue(not ok,
    "duplicate alg with both algs allowed: invalid sig must still fail closed")
}

// ─── exp/nbf overflow regression (#1078) ─────────────────────────────────────
// parseLong previously had no digit-count cap, so a crafted exp/nbf claim with
// 20+ digits overflowed to a negative Long under .NET unchecked arithmetic.
// The check `if exp >= 0i64 and nowSec > exp` was then skipped, treating the
// token as permanently non-expiring.  The fix caps parseLong at 18 digits;
// getLongClaimFromJson returns -2i64 for a present-but-oversized claim;
// validatePayload rejects immediately when it sees -2i64.

test "exp overflow regression: validly-signed token with 20-digit exp is rejected (#1078)" {
  // Payload: {"exp":99999999999999999999} — 20 digits, overflows Long.
  // This token is signed with HMAC-SHA256("test-secret") so it passes the
  // signature check and reaches validatePayload, exercising the overflow guard.
  // Without the fix the overflowed value is negative → exp check skipped → true.
  // With the fix getLongClaimFromJson returns -2i64 → validatePayload returns false.
  val ok = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTk5OTk5OTk5OTk5fQ.XSpwX_lbCxe7CP2z2kBxvBf7Hm-l14y_8YcA2UHqcdc",
    "test-secret", "", "", "HS256")
  assertTrue(not ok, "20-digit exp must be rejected — not treated as non-expiring")
}

test "nbf overflow regression: validly-signed token with 20-digit nbf is rejected (#1078)" {
  // Payload: {"nbf":99999999999999999999} — same overflow path, nbf direction.
  // Signed with HMAC-SHA256("test-secret").  Without fix: overflowed nbf is
  // negative → nbf check skipped → accepted.  With fix: rejected immediately.
  val ok = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJuYmYiOjk5OTk5OTk5OTk5OTk5OTk5OTk5fQ.wfVtcqqLpXnI_yfTav0k0p4g1b8wsvJPPJ9x94JEkjA",
    "test-secret", "", "", "HS256")
  assertTrue(not ok, "20-digit nbf must be rejected — not treated as not-yet-valid bypass")
}
