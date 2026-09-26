//! tests/auth_security_tests.l — security regression suite for the
//! lyric-auth library.
//!
//! Pins:
//!   * JWT algorithm-pinning (#315, #1090) — algorithm rejection surfaces
//!     a typed Err with ALG_REJECTED, distinguishable from BAD_SIGNATURE.
//!   * Role allow-list (#360).
//!   * exp/nbf overflow protection (#1078).
//!   * Clock-skew leeway (#1081) — default 60 s, configurable.
//!   * RFC 7519 §4.1.3 array-form `aud` (#1089).
//!   * JSON escape decoding in claim values (#1079).
//!   * parseLong: Result-typed, distinct overflow vs parse_error (#1088).
//!
//! Run via the multi-package test runner once issue #465 lands; until then
//! the test file serves as a living spec alongside the source.
@test_module
package Auth.AuthSecurityTests

import Std.Core
import Std.Testing
// `as Auth` is required by the AliasRewriter — see the historical comment
// in earlier revisions and #1094.  Tests below use `Auth.foo(...)` form,
// which the rewriter strips to `foo(...)` at codegen time.
import Auth as Auth

// ─── Role membership (#360) ───────────────────────────────────────────────────
test "rolesContain matches an exact single role" {
  assertTrue(Auth.rolesContain("admin", "admin"), "single-element allow-list matches identical role")
}

test "rolesContain matches one role from a comma-separated list" {
  assertTrue(Auth.rolesContain("admin,manager", "manager"), "manager is one of [admin, manager]")
  assertTrue(Auth.rolesContain("admin,manager", "admin"), "admin is one of [admin, manager]")
}

test "rolesContain rejects a role not in the allow-list" {
  assertTrue(not Auth.rolesContain("admin,manager", "viewer"), "viewer not in [admin, manager]")
}

test "rolesContain rejects an empty role claim" {
  assertTrue(not Auth.rolesContain("admin,manager", ""), "empty role must not match")
}

test "rolesContain rejects against an empty allow-list" {
  assertTrue(not Auth.rolesContain("", "admin"), "empty allow-list must reject every role")
}

test "rolesContain trims whitespace around comma-separated entries (#360)" {
  assertTrue(Auth.rolesContain("admin, manager", "manager"), "leading space after comma should not break role matching")
  assertTrue(Auth.rolesContain(" admin , manager ", "admin"), "surrounding whitespace should be tolerated")
  assertTrue(Auth.rolesContain("admin,\tmanager", "manager"), "tab after comma should be tolerated")
}

test "rolesContain skips empty / whitespace-only entries" {
  assertTrue(not Auth.rolesContain("admin, ,manager", " "), "whitespace-only entry must not match a whitespace role")
  // Trailing comma must not create an empty match path that lets an
  // empty role claim slip through (defense-in-depth — empty role is
  // already rejected at the boundary).
  assertTrue(not Auth.rolesContain("admin,", ""), "trailing comma must not match empty role")
}

// ─── JWT algorithm pinning (#315, #1090) ──────────────────────────────────────
//
// The empty-allow-list case is enforced by the
// `requires: allowedAlgorithms.length > 0` contract at the boundary —
// under @runtime_checked it triggers an unrecoverable panic, which user
// code cannot catch.  Tests pin only the post-contract invariants: that
// the allow-list is positional, threaded through to the underlying
// verifier, and that verification fails closed on junk input for both
// single- and multi-algorithm pins.
//
// `verifyJwt` returns `Result[Unit, JwtError]` (#1090); tests inline the
// match instead of factoring a helper function because the bootstrap type
// checker rejects `Auth.JwtError` in function signatures inside
// @test_module files.
test "verifyJwt with a malformed token under HS256 pin returns Err" {
  val r = Auth.verifyJwt("not.a.jwt", "lyric-test-hs256-signing-key-0123456789", "issuer-x", "audience-y", "HS256")
  val isOk = match r { case Ok(v) -> true; case Err(e) -> false }
  assertTrue(not isOk, "malformed token must fail closed under HS256 pin")
}

test "verifyJwt multi-algorithm pin (HS256,RS256) still fails closed on junk" {
  val r = Auth.verifyJwt(
    "not.a.jwt",
    "lyric-test-hs256-signing-key-0123456789",
    "issuer-x",
    "audience-y",
    "HS256,RS256"
  )
  val isOk = match r { case Ok(v) -> true; case Err(e) -> false }
  assertTrue(not isOk, "multi-algorithm pin must still fail closed on junk")
}

// ─── jwtAlg extraction (#553) ─────────────────────────────────────────────────
// jwtAlg is package-private; tested via verifyJwt which short-circuits to Err
// before the kernel when the extracted alg is missing or not in the allow-list.
test "jwtAlg: no-padding header (rem==0) correctly extracts HS256" {
  // Header: {"alg":"HS256","typ":"JWT"} → eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 (len=36, rem=0)
  // Alg is HS256 which IS in the allow-list, so we reach the kernel.
  // The kernel rejects the fake signature with BAD_SIGNATURE.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.fakesig",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(
    code,
    "BAD_SIGNATURE",
    "HS256 + fake signature → BAD_SIGNATURE (alg passed pinning, signature did not verify)"
  )
}

test "jwtAlg: missing alg returns MALFORMED_HEADER (rem==2 padding path)" {
  // Header: {"typ":"JWT"} → eyJ0eXAiOiJKV1QifQ (len=18, rem=2; needs == padding)
  // No "alg" key → Lyric-level jwtAlg returns "" → MALFORMED_HEADER.
  val r = Auth.verifyJwt(
    "eyJ0eXAiOiJKV1QifQ.payload.fakesig",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "MALFORMED_HEADER", "missing alg → MALFORMED_HEADER (no algorithm to enforce)")
}

test "jwtAlg: empty JSON header has no alg (rem==3 padding path)" {
  // Header: {} → e30 (len=3, rem=3; needs = padding)
  val r = Auth.verifyJwt("e30.payload.fakesig", "lyric-test-hs256-signing-key-0123456789", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "MALFORMED_HEADER", "empty header object → MALFORMED_HEADER")
}

test "jwtAlg: invalid rem==1 segment is treated as malformed" {
  // A base64url segment whose length % 4 == 1 is not valid base64url.
  // "aaaaa" is 5 chars; 5 % 4 = 1.
  val r = Auth.verifyJwt("aaaaa.payload.fakesig", "lyric-test-hs256-signing-key-0123456789", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "MALFORMED_HEADER", "rem==1 header → MALFORMED_HEADER")
}

test "jwtAlg: token with no dot separator fails closed" {
  val r = Auth.verifyJwt("nodot", "lyric-test-hs256-signing-key-0123456789", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "MALFORMED_HEADER", "no dot in token → MALFORMED_HEADER (no header to parse)")
}

// ─── #1090: typed Err for algorithm rejection ─────────────────────────────────
// Algorithm rejection MUST surface a distinct Err code (ALG_REJECTED) so
// callers can tell it apart from a cryptographic signature failure.  Before
// #1090 every non-success collapsed into a bare `false`, masking the
// distinction.
test "verifyJwt: alg not in allow-list returns Err(ALG_REJECTED) (#1090)" {
  // Header: {"alg":"RS256"} → eyJhbGciOiJSUzI1NiJ9 (len=20, rem=0)
  // allowedAlgorithms = "HS256" → ALG_REJECTED at the Lyric layer, before kernel.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJSUzI1NiJ9.payload.fakesig",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "ALG_REJECTED", "alg not in allowedAlgorithms → ALG_REJECTED (not BAD_SIGNATURE)")
}

test "verifyJwt: ALG_REJECTED is distinct from BAD_SIGNATURE (#1090)" {
  // Same header but allow-list now includes HS256 only.  The two Err codes
  // are produced by different paths; this test pins that they differ.
  val rsRejected = Auth.verifyJwt(
    "eyJhbGciOiJSUzI1NiJ9.payload.fakesig",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  val hsBadSig = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.fakesig",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  val codeRs = match rsRejected { case Ok(v) -> "OK"; case Err(e) -> e.code }
  val codeHs = match hsBadSig { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertTrue(codeRs != codeHs, "ALG_REJECTED and BAD_SIGNATURE must be distinguishable error codes")
  assertEqual(codeRs, "ALG_REJECTED", "alg-not-in-allow-list code")
  assertEqual(codeHs, "BAD_SIGNATURE", "alg-allowed-but-sig-fails code")
}

// ─── alg=none forgery / algorithm-pinning end-to-end regression (#5636) ──────
// RFC 8725 §3.1 requires rejecting a token whose `alg` header is `none` (an
// unsigned-token forgery) or any algorithm outside the caller's allow-list
// (HS256/RS256 confusion).  `verifyJwt` itself forbids "none" from ever
// appearing in the caller's allow-list via its `requires:` contract, so an
// attacker-supplied `alg=none` header can never be in `allowedAlgorithms`
// and always falls through to `ALG_REJECTED` before the kernel is reached.
// These three tests pin the full trio end to end: alg=none rejected,
// mismatched alg rejected, and a correctly-signed matching-alg token
// accepted — confirming there is no live gap on `--target dotnet`.  The
// Lyric-level `jwtAlg` belt-and-suspenders extraction (auth.l) uses the
// Option-returning `.indexOf` spelling on both targets since #6348 fixed
// the #5625 MSIL mis-binding.
test "verifyJwt: alg=none forged token is rejected as ALG_REJECTED, not accepted (#5636)" {
  // Header: {"alg":"none"} → eyJhbGciOiJub25lIn0 (len=19, rem=3; needs = padding).
  // Classic alg=none forgery drops the signature; the empty final segment
  // does not matter here since alg pinning short-circuits before signature
  // verification is ever attempted.
  val r = Auth.verifyJwt("eyJhbGciOiJub25lIn0.payload.", "lyric-test-hs256-signing-key-0123456789", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "ALG_REJECTED", "alg=none forged token must be rejected, never accepted (RFC 8725 §3.1)")
}

test "verifyJwt: HS256/RS256 confusion (RS256 token, HS256-only allow-list) is rejected (#5636)" {
  // Header: {"alg":"RS256"} → eyJhbGciOiJSUzI1NiJ9 (len=20, rem=0).
  val r = Auth.verifyJwt(
    "eyJhbGciOiJSUzI1NiJ9.payload.fakesig",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "ALG_REJECTED", "alg confusion (RS256 token against an HS256-only pin) must be rejected")
}

test "verifyJwt: correctly-signed matching-alg token is accepted (#5636)" {
  // Header: {"alg":"HS256"}, payload {"iss":"alice"}, signed with
  // HMAC-SHA256("lyric-test-hs256-signing-key-0123456789") — reconstruction documented in the Python
  // snippet above.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImlzcyI6ImFsaWNlIn0.OUvrtEAJU_m8JJj9941DHRIXfZGDG6DpIZfxCf_ox_c",
    "lyric-test-hs256-signing-key-0123456789",
    "alice",
    "",
    "HS256"
  )
  val isOk = match r { case Ok(v) -> true; case Err(e) -> false }
  assertTrue(isOk, "a correctly-signed token whose alg matches the allow-list must verify")
}

// ─── Duplicate alg key attack regression (#560) ───────────────────────────────
// RFC 8259 §4 permits duplicate keys; last-wins is common in many JSON parsers.
// A crafted header {"alg":"RS256","alg":"HS256"} tries to mask the real alg behind
// a trusted-looking first alg value.  lastIndexOf in jwtAlg picks up "HS256" (last),
// which is then checked against the allow-list — so the attack is detected.
test "duplicate alg attack: lastIndexOf picks last alg, rejects wrong algorithm" {
  // Header: {"alg":"RS256","typ":"JWT","alg":"HS256"} (last alg = HS256)
  // → eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImFsZyI6IkhTMjU2In0 (len=55, rem=3; needs = padding)
  // allowedAlgorithms = "RS256" — last alg is "HS256" which is not in {"RS256"}.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImFsZyI6IkhTMjU2In0.payload.fakesig",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "RS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(
    code,
    "ALG_REJECTED",
    "duplicate alg header: last alg (HS256) not in RS256-only allow-list — ALG_REJECTED"
  )
}

test "duplicate alg attack: both algs in allow-list — still fails on invalid sig" {
  // Header: same duplicate alg header (last alg = HS256), but now HS256 IS allowed.
  // jwtAlg returns "HS256"; rolesContain("HS256,RS256","HS256") = true → kernel called.
  // Kernel rejects the fake signature → BAD_SIGNATURE.  Confirms lastIndexOf picks
  // "HS256" and that the token is still validated (not silently accepted).
  val r = Auth.verifyJwt(
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImFsZyI6IkhTMjU2In0.payload.fakesig",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256,RS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "BAD_SIGNATURE", "alg accepted, signature rejected → BAD_SIGNATURE")
}

// ─── exp/nbf overflow regression (#1078) ─────────────────────────────────────
// parseLong previously had no digit-count cap, so a crafted exp/nbf claim with
// 20+ digits overflowed to a negative Long under .NET unchecked arithmetic.
// The check `if exp >= 0i64 and nowSec >= exp` was then skipped, treating the
// token as permanently non-expiring.  The fix caps parseLong at 18 digits;
// getLongClaimFromJson returns Err("overflow") for a present-but-oversized
// claim; validatePayload rejects immediately with EXP_OVERFLOW / NBF_OVERFLOW.
//
// Test tokens below were generated with the following Python snippet so they
// are reproducible and auditable (#1091).  Every token carries an `exp` (a
// token without one is rejected, MISSING_EXP) and is signed with a key of at
// least 32 bytes (the HS256 minimum, #7232).  Re-run when the test structure or
// secret changes — without the right signature the overflow guard would be
// bypassed at the signature check, producing a false-pass.
//
// ```python
// import base64, hmac, hashlib
// def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
// def make(payload_json: bytes, key: bytes = b"lyric-test-hs256-signing-key-0123456789") -> str:
//     header  = b64url(b'{"alg":"HS256"}')
//     payload = b64url(payload_json)
//     sig     = hmac.new(key, f"{header}.{payload}".encode(),
//                        hashlib.sha256).digest()
//     return f"{header}.{payload}.{b64url(sig)}"
//
// # exp overflow regression:
// print(make(b'{"exp":99999999999999999999}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTk5OTk5OTk5OTk5fQ.se7xoGxONkIXafEKp4jzzVEgJBz7_L4xEju59o2O05s
//
// # nbf overflow regression:
// print(make(b'{"exp":4102444800,"nbf":99999999999999999999}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsIm5iZiI6OTk5OTk5OTk5OTk5OTk5OTk5OTl9.-nbqFSpf4bs6r7srLiaBr855SnLw-6C15BF2shlysH0
//
// # iss=alice payload (matches "alice" issuer test):
// print(make(b'{"exp":4102444800,"iss":"alice"}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImlzcyI6ImFsaWNlIn0.OUvrtEAJU_m8JJj9941DHRIXfZGDG6DpIZfxCf_ox_c
//
// # array-form aud {"aud":["api.example.com","admin"]}:
// print(make(b'{"exp":4102444800,"aud":["api.example.com","admin"]}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6WyJhcGkuZXhhbXBsZS5jb20iLCJhZG1pbiJdfQ.M8c8ZP7lWBggIPaJ7t4_qbCl-eEkKVQhXMwcJ9qluVI
//
// # string-form aud {"aud":"api.example.com"}:
// print(make(b'{"exp":4102444800,"aud":"api.example.com"}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6ImFwaS5leGFtcGxlLmNvbSJ9.piL9RwsNpiLZ5_i7NRhKcwb-YgaO7dlTxyfWZ2MMpho
//
// # sub with embedded quote {"sub":"O\"Brien"}:
// print(make(b'{"exp":4102444800,"sub":"O\\"Brien"}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsInN1YiI6Ik9cIkJyaWVuIn0.cqSgeul0BV6hwOE0IiRakbJT7ydlsWRTaZJp2p1znIU
//
// # exp=1 (deep past) used by clock-skew tests:
// print(make(b'{"exp":1}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.jYyPYvlImlPdrmVWWkXXngP9OG7Piue_xkqojNE_Nnw
//
// # non-numeric exp:
// print(make(b'{"exp":"abc"}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOiJhYmMifQ.23ou6OL91_FJDdTAQ7T-5I9pMmINy75aNEU_gMB2CkI
// ```
test "exp non-numeric regression: validly-signed token with string exp is rejected (#1161)" {
  // Payload: {"exp":"abc"} — non-numeric exp claim.
  // getLongClaimFromJson returns Err("parse_error"); validatePayload maps all
  // getLongClaimFromJson errors to EXP_OVERFLOW (intentional: both parse-error
  // and arithmetic-overflow indicate a malformed/unsafe exp claim).
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOiJhYmMifQ.23ou6OL91_FJDdTAQ7T-5I9pMmINy75aNEU_gMB2CkI",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(
    code,
    "EXP_OVERFLOW",
    "non-numeric exp → EXP_OVERFLOW (both parse-error and overflow map to the same code)"
  )
}

test "exp overflow regression: validly-signed token with 20-digit exp is rejected (#1078)" {
  // Payload: {"exp":99999999999999999999} — 20 digits, overflows Long.
  // Without the fix the overflowed value is negative → exp check skipped → Ok.
  // With the fix parseLong returns Err("overflow") → EXP_OVERFLOW.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTk5OTk5OTk5OTk5fQ.se7xoGxONkIXafEKp4jzzVEgJBz7_L4xEju59o2O05s",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "EXP_OVERFLOW", "20-digit exp → EXP_OVERFLOW (parseLong overflow → typed error code)")
}

test "nbf overflow regression: validly-signed token with 20-digit nbf is rejected (#1078)" {
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsIm5iZiI6OTk5OTk5OTk5OTk5OTk5OTk5OTl9.-nbqFSpf4bs6r7srLiaBr855SnLw-6C15BF2shlysH0",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "NBF_OVERFLOW", "20-digit nbf → NBF_OVERFLOW")
}

// ─── #1089: RFC 7519 §4.1.3 array-form aud ────────────────────────────────────
test "verifyJwt: array-form aud containing expected audience verifies (#1089)" {
  // Payload: {"aud":["api.example.com","admin"]}, signed with HMAC-SHA256("lyric-test-hs256-signing-key-0123456789").
  // Token reconstruction documented in the Python snippet above.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6WyJhcGkuZXhhbXBsZS5jb20iLCJhZG1pbiJdfQ.M8c8ZP7lWBggIPaJ7t4_qbCl-eEkKVQhXMwcJ9qluVI",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "api.example.com",
    "HS256"
  )
  val isOk = match r { case Ok(v) -> true; case Err(e) -> false }
  assertTrue(isOk, "array-form aud containing the expected audience must verify (RFC 7519 §4.1.3)")
}

test "verifyJwt: array-form aud not containing expected audience returns AUDIENCE_MISMATCH (#1089)" {
  // Same array-form aud but the caller expects "billing" which is not in the array.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6WyJhcGkuZXhhbXBsZS5jb20iLCJhZG1pbiJdfQ.M8c8ZP7lWBggIPaJ7t4_qbCl-eEkKVQhXMwcJ9qluVI",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "billing",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "AUDIENCE_MISMATCH", "audience absent from array → AUDIENCE_MISMATCH")
}

test "verifyJwt: string-form aud still verifies (#1089 backwards-compat)" {
  // Payload: {"aud":"api.example.com"}.  The string form must continue to work
  // — the array support is additive, not a replacement.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6ImFwaS5leGFtcGxlLmNvbSJ9.piL9RwsNpiLZ5_i7NRhKcwb-YgaO7dlTxyfWZ2MMpho",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "api.example.com",
    "HS256"
  )
  val isOk = match r { case Ok(v) -> true; case Err(e) -> false }
  assertTrue(isOk, "single-string aud match must continue to verify")
}

// ─── #2714: duplicate aud keys must be rejected ───────────────────────────────
// RFC 8259 §4 says duplicate JSON keys SHOULD NOT appear.  In a security
// context the ambiguity is exploitable: one system may resolve the first
// occurrence while another resolves the last.  `verifyJwt` rejects tokens
// with any duplicate `aud` key with AUDIENCE_MISMATCH, regardless of whether
// the token's audience might otherwise match (#2714).
//
// These two tests update the earlier #1289 regression tests which pinned
// last-wins behavior on cross-form duplicate `aud` payloads.  The tokens
// are unchanged; the expected error is now AUDIENCE_MISMATCH in all cases
// because the duplicate-detection fires before audience matching.
//
// Token construction (Python snippet above):
//   # string-form before array-form:
//   print(make(b'{"exp":4102444800,"aud":"string-form","aud":["api.example.com","admin"]}'))
//   # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6InN0cmluZy1mb3JtIiwiYXVkIjpbImFwaS5leGFtcGxlLmNvbSIsImFkbWluIl19._Kt0c_74VWfUIYUs_uQzoASDul1uZUI9so52vaDylD8
//
//   # array-form before string-form:
//   print(make(b'{"exp":4102444800,"aud":["api.example.com","admin"],"aud":"string-form"}'))
//   # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6WyJhcGkuZXhhbXBsZS5jb20iLCJhZG1pbiJdLCJhdWQiOiJzdHJpbmctZm9ybSJ9.2NjfAfP5wiHNz1aeycq29dM88O1BDw36205qsr1BeQA
test "duplicate aud: string-form before array-form is rejected with AUDIENCE_MISMATCH (#2714)" {
  // Payload: {"aud":"string-form","aud":["api.example.com","admin"]}
  // Both string-form and array-form present → duplicate aud key detected →
  // AUDIENCE_MISMATCH before audience matching.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6InN0cmluZy1mb3JtIiwiYXVkIjpbImFwaS5leGFtcGxlLmNvbSIsImFkbWluIl19._Kt0c_74VWfUIYUs_uQzoASDul1uZUI9so52vaDylD8",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "api.example.com",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(
    code,
    "AUDIENCE_MISMATCH",
    "duplicate aud (string-form then array-form) must be rejected with AUDIENCE_MISMATCH (#2714)"
  )
}

test "duplicate aud: array-form before string-form is rejected with AUDIENCE_MISMATCH (#2714)" {
  // Payload: {"aud":["api.example.com","admin"],"aud":"string-form"}
  // Same duplicate-aud rejection regardless of which form appears first.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6WyJhcGkuZXhhbXBsZS5jb20iLCJhZG1pbiJdLCJhdWQiOiJzdHJpbmctZm9ybSJ9.2NjfAfP5wiHNz1aeycq29dM88O1BDw36205qsr1BeQA",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "api.example.com",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(
    code,
    "AUDIENCE_MISMATCH",
    "duplicate aud (array-form then string-form) must be rejected with AUDIENCE_MISMATCH (#2714)"
  )
}

// ─── #3165: structural JSON parsing eliminates pattern-scan false positives ──
// Follow-up to #2714/#3144.  The pre-#3165 `audHasDuplicates` scanned the raw
// payload text for literal `"aud":"` / `"aud":[` byte sequences rather than
// building a JSON parse tree, so it could not distinguish a genuine
// TOP-LEVEL `aud` claim from an unrelated claim whose VALUE happens to be an
// object/array that itself has a nested key named "aud".  A payload with one
// genuine top-level `aud` PLUS one nested "aud" (inside `sub`, three levels
// deep) produced two raw occurrences of `"aud":"`, tripping the duplicate
// check and rejecting an otherwise perfectly valid token with
// AUDIENCE_MISMATCH.  The structural parser (#3165) only counts TOP-LEVEL
// fields, so it correctly sees exactly one `aud` key and accepts the token.
//
// Token construction (same Python snippet convention as above):
//   print(make(b'{"exp":4102444800,"aud":"real-audience","sub":{"aud":"decoy"},"iss":"trusted"}'))
//   # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6InJlYWwtYXVkaWVuY2UiLCJzdWIiOnsiYXVkIjoiZGVjb3kifSwiaXNzIjoidHJ1c3RlZCJ9.uk4zhZLesj0y5GwrPZtionRWrCIqyMiqw9qGtFJ2oWc
test "structural parsing: nested \"aud\" inside an unrelated claim's object value does not trigger a false duplicate-aud rejection (#3165)" {
  val token = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImF1ZCI6InJlYWwtYXVkaWVuY2UiLCJzdWIiOnsiYXVkIjoiZGVjb3kifSwiaXNzIjoidHJ1c3RlZCJ9.uk4zhZLesj0y5GwrPZtionRWrCIqyMiqw9qGtFJ2oWc"
  val r = Auth.verifyJwt(token, "lyric-test-hs256-signing-key-0123456789", "trusted", "real-audience", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(
    code,
    "OK",
    "genuine top-level aud + unrelated nested \"aud\" (inside sub) must verify — not a duplicate-aud false positive"
  )
}

// ─── #6573: parser depth cap — unbounded-recursion pre-auth DoS ──────────────
// The #3165 recursive-descent parser above had no recursion-depth limit, and
// `jwtAlgFromHeader` runs on the fully attacker-controlled header BEFORE the
// HMAC signature is ever checked (see `verifyJwtImpl` — header parse happens
// first, signature verification only after alg allow-listing).  An
// unauthenticated attacker could submit a token whose header (or payload) is
// nested far deeper than any legitimate JWT claim shape and drive the parser
// into unbounded recursion — on .NET this surfaces as an uncatchable
// StackOverflowException that kills the whole process, not a normal
// exception a caller could handle.  The fix caps recursion at
// `jsonMaxDepth` (32) in both kernels, failing closed with
// MALFORMED_HEADER/MALFORMED_PAYLOAD once exceeded.
//
// Both tokens below nest 40 levels of `{"a": ... }` — comfortably past the
// cap — generated with:
//   def nested(depth):
//     v = "leaf"
//     for _ in range(depth): v = {"a": v}
//     return v
//
// Header case: header = {"alg":"HS256","nested": nested(40)}, third segment
// is arbitrary garbage — the depth-capped header parse must fail BEFORE any
// signature check runs, so an invalid signature does not change the outcome.
test "structural parsing: over-depth JWT header fails closed as MALFORMED_HEADER instead of crashing (#6573)" {
  val token = "eyJhbGciOiJIUzI1NiIsIm5lc3RlZCI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjoibGVhZiJ9fX19fX19fX19fX19fX19fX19fX19fX19fX19fX19fX19fX19fX19fQ.eyJzdWIiOiJ4In0.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  val r = Auth.verifyJwt(token, "lyric-test-hs256-signing-key-0123456789", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(
    code,
    "MALFORMED_HEADER",
    "40-level-nested header must be rejected as MALFORMED_HEADER (depth cap), not crash the process (#6573)"
  )
}

// Payload case: header is a normal `{"alg":"HS256"}`, signature is a real
// HMAC-SHA256("lyric-test-hs256-signing-key-0123456789") over header.payload so the token reaches
// `validatePayload` — payload = {"sub":"x","nested": nested(40)}.
test "structural parsing: over-depth JWT payload fails closed as MALFORMED_PAYLOAD instead of crashing (#6573)" {
  val token = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsInN1YiI6IngiLCJuZXN0ZWQiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6eyJhIjp7ImEiOnsiYSI6ImxlYWYifX19fX19fX19fX19fX19fX19fX19fX19fX19fX19fX19fX19fX19fX0.VlAjmXqC7HZryFL2s6-iu9R2FQiAeMvdK5Qu86akvj0"
  val r = Auth.verifyJwt(token, "lyric-test-hs256-signing-key-0123456789", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(
    code,
    "MALFORMED_PAYLOAD",
    "40-level-nested payload must be rejected as MALFORMED_PAYLOAD (depth cap), not crash the process (#6573)"
  )
}

// ─── #1079: JSON escape decoding in claim values ─────────────────────────────
// extractClaim must decode standard JSON escape sequences in the claim value.
// Before #1079 a `sub` claim of `"O\"Brien"` was returned as the literal bytes
// `O\"Brien` (with the backslash), and `"line1\nline2"` was returned with a
// literal `\n` rather than a real newline.
test "extractClaim: claim value with escaped quote is decoded (#1079)" {
  // Payload: {"sub":"O\"Brien"} (after JSON unescaping it is O"Brien).
  // Signed with HMAC-SHA256("lyric-test-hs256-signing-key-0123456789").
  val token = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsInN1YiI6Ik9cIkJyaWVuIn0.cqSgeul0BV6hwOE0IiRakbJT7ydlsWRTaZJp2p1znIU"
  // First confirm verification passes (so we know the payload is parsed).
  val v = Auth.verifyJwt(token, "lyric-test-hs256-signing-key-0123456789", "", "", "HS256")
  val isOk = match v { case Ok(u) -> true; case Err(e) -> false }
  assertTrue(isOk, "token with escaped sub value must still verify (signature is over the encoded payload)")
  match Auth.extractClaim(token, "sub") {
    case None -> assertTrue(false, "sub claim must be extracted")
    case Some(value) -> {
      assertEqual(value, "O\"Brien", "escaped quote in sub must decode to a literal quote character (#1079)")
    }
  }
}

test "extractClaim: simple ASCII claim still extracts (#1079 regression guard)" {
  // Payload: {"iss":"alice"} — no escapes.  This passes pre- and post-fix.
  val token = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDAsImlzcyI6ImFsaWNlIn0.OUvrtEAJU_m8JJj9941DHRIXfZGDG6DpIZfxCf_ox_c"
  match Auth.extractClaim(token, "iss") {
    case None -> assertTrue(false, "iss claim must be extracted")
    case Some(value) -> assertEqual(value, "alice", "simple ASCII claim extracts identically")
  }
}

// ─── #1081: clock-skew leeway ─────────────────────────────────────────────────
// We cannot easily test the wall-clock interaction in unit tests, so we exercise
// the parameter plumbing and contract: skewSeconds=0 must enforce strict
// expiry semantics, and the default skew is exposed for callers via
// defaultClockSkewSeconds().
test "defaultClockSkewSeconds is 60 (#1081)" {
  assertTrue(Auth.defaultClockSkewSeconds() == 60, "industry-standard 60-second leeway (Auth0, AWS Cognito)")
}

test "verifyJwtWithSkew: zero skew with an expired token rejects (#1081)" {
  // exp = 1 (1970-01-01T00:00:01Z) is in the deep past for any test run.
  // Token construction documented in the Python snippet above.
  val r = Auth.verifyJwtWithSkew(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.jYyPYvlImlPdrmVWWkXXngP9OG7Piue_xkqojNE_Nnw",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256",
    0
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "EXPIRED", "exp in the past with zero skew → EXPIRED")
}

test "verifyJwtWithSkew: the leeway is capped at 300 seconds (#1081, #7232)" {
  // This test used a 2_000_000_000-second skew to show the window widening.
  // Leeway is now capped at `maxClockSkewSeconds()` (RFC 7519 §4.1.4: "a
  // few minutes"): an unbounded skew silently extends every token's
  // lifetime.  The cap itself is the precondition; the widening arithmetic
  // (`exp + skew`) stays covered by the zero-skew EXPIRED case above.
  assertEqualInt(Auth.maxClockSkewSeconds(), 300, "cap")
  val atCap = Auth.verifyJwtWithSkew(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.jYyPYvlImlPdrmVWWkXXngP9OG7Piue_xkqojNE_Nnw",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256",
    300
  )
  val code = match atCap { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "EXPIRED", "exp=1 is far outside a 300-second leeway")
  assertPanics(
    "skew above the cap",
    { ->
      val _ = Auth.verifyJwtWithSkew(
        "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.jYyPYvlImlPdrmVWWkXXngP9OG7Piue_xkqojNE_Nnw",
        "lyric-test-hs256-signing-key-0123456789",
        "",
        "",
        "HS256",
        2000000000
      )
    }
  )
}

// ─── #1090: ALG_UNSUPPORTED vs ALG_REJECTED ──────────────────────────────────
// When the caller allow-lists an algorithm the kernel does not implement
// (e.g. RS256 on the .NET kernel today, #443), we surface ALG_UNSUPPORTED
// rather than masking it as BAD_SIGNATURE.
test "verifyJwt: alg allowed but unsupported by kernel returns ALG_UNSUPPORTED (#1090)" {
  // Token alg = RS256, caller allows RS256, but the .NET kernel only
  // implements HS256.  Surface this as ALG_UNSUPPORTED so operators see
  // the kernel limitation in logs instead of a generic verification failure.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJSUzI1NiJ9.payload.fakesig",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "RS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "ALG_UNSUPPORTED", "alg-allowed-but-not-implemented → ALG_UNSUPPORTED (not BAD_SIGNATURE)")
}

// ─── #7232 hardening ────────────────────────────────────────────────────────
// A validly-signed token with no exp claim never expires; it is rejected.
//   print(make(b'{"sub":"no-expiry"}'))
//   # → eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJuby1leHBpcnkifQ.tPoHeU9jXk-qJCI0-fMVAb2VJbrZQ40m7d_bPXld-DA
test "a validly-signed token without an exp claim is rejected with MISSING_EXP (#7232)" {
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJuby1leHBpcnkifQ.tPoHeU9jXk-qJCI0-fMVAb2VJbrZQ40m7d_bPXld-DA",
    "lyric-test-hs256-signing-key-0123456789",
    "",
    "",
    "HS256"
  )
  match r {
    case Ok(_) -> assertTrue(false, "a token with no exp must not verify")
    case Err(e) -> assertEqual(e.code, "MISSING_EXP", "error code")
  }
}

test "an HMAC secret shorter than 32 bytes violates the precondition (#7232)" {
  assertTrue(not Auth.isStrongHmacSecret("test-secret"), "11 bytes is too short")
  assertTrue(Auth.isStrongHmacSecret("lyric-test-hs256-signing-key-0123456789"), "39 bytes is enough")
  assertPanics(
    "short secret",
    { ->
      val _ = Auth.verifyJwt(
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJuby1leHBpcnkifQ.tPoHeU9jXk-qJCI0-fMVAb2VJbrZQ40m7d_bPXld-DA",
        "test-secret",
        "",
        "",
        "HS256"
      )
    }
  )
}

test "a clock-skew leeway above 300 seconds violates the precondition (#7232)" {
  assertPanics(
    "skew 3600",
    { ->
      val _ = Auth.verifyJwtWithSkew(
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJuby1leHBpcnkifQ.tPoHeU9jXk-qJCI0-fMVAb2VJbrZQ40m7d_bPXld-DA",
        "lyric-test-hs256-signing-key-0123456789",
        "",
        "",
        "HS256",
        3600
      )
    }
  )
}

test "verifyApiKey rejects keys of a different length without leaking it (#7232)" {
  assertTrue(Auth.verifyApiKey("key-abc-123", "key-abc-123"), "equal keys verify")
  assertTrue(not Auth.verifyApiKey("key", "key-abc-123"), "shorter key")
  assertTrue(not Auth.verifyApiKey("key-abc-1234567890", "key-abc-123"), "longer key")
  assertTrue(not Auth.verifyApiKey("key-abc-124", "key-abc-123"), "same length, different key")
}
