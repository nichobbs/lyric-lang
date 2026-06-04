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
  val r = Auth.verifyJwt("not.a.jwt", "test-secret", "issuer-x", "audience-y", "HS256")
  val isOk = match r { case Ok(v) -> true; case Err(e) -> false }
  assertTrue(not isOk, "malformed token must fail closed under HS256 pin")
}

test "verifyJwt multi-algorithm pin (HS256,RS256) still fails closed on junk" {
  val r = Auth.verifyJwt("not.a.jwt", "test-secret", "issuer-x", "audience-y", "HS256,RS256")
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
  val r = Auth.verifyJwt("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.fakesig", "test-secret", "", "", "HS256")
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
  val r = Auth.verifyJwt("eyJ0eXAiOiJKV1QifQ.payload.fakesig", "test-secret", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "MALFORMED_HEADER", "missing alg → MALFORMED_HEADER (no algorithm to enforce)")
}

test "jwtAlg: empty JSON header has no alg (rem==3 padding path)" {
  // Header: {} → e30 (len=3, rem=3; needs = padding)
  val r = Auth.verifyJwt("e30.payload.fakesig", "test-secret", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "MALFORMED_HEADER", "empty header object → MALFORMED_HEADER")
}

test "jwtAlg: invalid rem==1 segment is treated as malformed" {
  // A base64url segment whose length % 4 == 1 is not valid base64url.
  // "aaaaa" is 5 chars; 5 % 4 = 1.
  val r = Auth.verifyJwt("aaaaa.payload.fakesig", "test-secret", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "MALFORMED_HEADER", "rem==1 header → MALFORMED_HEADER")
}

test "jwtAlg: token with no dot separator fails closed" {
  val r = Auth.verifyJwt("nodot", "test-secret", "", "", "HS256")
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
  val r = Auth.verifyJwt("eyJhbGciOiJSUzI1NiJ9.payload.fakesig", "test-secret", "", "", "HS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "ALG_REJECTED", "alg not in allowedAlgorithms → ALG_REJECTED (not BAD_SIGNATURE)")
}

test "verifyJwt: ALG_REJECTED is distinct from BAD_SIGNATURE (#1090)" {
  // Same header but allow-list now includes HS256 only.  The two Err codes
  // are produced by different paths; this test pins that they differ.
  val rsRejected = Auth.verifyJwt("eyJhbGciOiJSUzI1NiJ9.payload.fakesig", "test-secret", "", "", "HS256")
  val hsBadSig = Auth.verifyJwt("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.fakesig", "test-secret", "", "", "HS256")
  val codeRs = match rsRejected { case Ok(v) -> "OK"; case Err(e) -> e.code }
  val codeHs = match hsBadSig { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertTrue(codeRs != codeHs, "ALG_REJECTED and BAD_SIGNATURE must be distinguishable error codes")
  assertEqual(codeRs, "ALG_REJECTED", "alg-not-in-allow-list code")
  assertEqual(codeHs, "BAD_SIGNATURE", "alg-allowed-but-sig-fails code")
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
    "test-secret",
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
    "test-secret",
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
// are reproducible and auditable (#1091).  Re-run when the test structure or
// secret changes — without the right signature the overflow guard would be
// bypassed at the signature check, producing a false-pass.
//
// ```python
// import base64, hmac, hashlib
// def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
// def make(payload_json: bytes, key: bytes = b"test-secret") -> str:
//     header  = b64url(b'{"alg":"HS256"}')
//     payload = b64url(payload_json)
//     sig     = hmac.new(key, f"{header}.{payload}".encode(),
//                        hashlib.sha256).digest()
//     return f"{header}.{payload}.{b64url(sig)}"
//
// # exp overflow regression:
// print(make(b'{"exp":99999999999999999999}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTk5OTk5OTk5OTk5fQ.XSpwX_lbCxe7CP2z2kBxvBf7Hm-l14y_8YcA2UHqcdc
//
// # nbf overflow regression:
// print(make(b'{"nbf":99999999999999999999}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJuYmYiOjk5OTk5OTk5OTk5OTk5OTk5OTk5fQ.wfVtcqqLpXnI_yfTav0k0p4g1b8wsvJPPJ9x94JEkjA
//
// # iss=alice payload (matches "alice" issuer test):
// print(make(b'{"iss":"alice"}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJhbGljZSJ9.5aKgRbW0s3yamkNfocjRYD-wgC2m6fedIAg2c6k8I1c
//
// # array-form aud {"aud":["api.example.com","admin"]}:
// print(make(b'{"aud":["api.example.com","admin"]}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOlsiYXBpLmV4YW1wbGUuY29tIiwiYWRtaW4iXX0.MaU1v7iUF4ZuurYpCTzGSeJQaGpj-PgemuvBvUZUwJE
//
// # string-form aud {"aud":"api.example.com"}:
// print(make(b'{"aud":"api.example.com"}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJhcGkuZXhhbXBsZS5jb20ifQ.IO4WPTpwyrGklp1bW9Gnu_ETf8-b-PMSxkT_OKctPnc
//
// # sub with embedded quote {"sub":"O\"Brien"}:
// print(make(b'{"sub":"O\\"Brien"}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJPXCJCcmllbiJ9.0nB7w7b6e6YyAFrSNy7OjM2q26WIoSykU-cv0sw1xC0
//
// # exp=1 (deep past) used by clock-skew tests:
// print(make(b'{"exp":1}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.ll37qi5BStXya0qqqwLHM0oKvWoHHZMdnStJSCMiyPM
//
// # non-numeric exp:
// print(make(b'{"exp":"abc"}'))
// # → eyJhbGciOiJIUzI1NiJ9.eyJleHAiOiJhYmMifQ.NCnzMSVqHiR3EKJFPFXm7gGpVfsgxO7Q7nY_Kf_3E5I
// ```
test "exp overflow regression: validly-signed token with 20-digit exp is rejected (#1078)" {
  // Payload: {"exp":99999999999999999999} — 20 digits, overflows Long.
  // Without the fix the overflowed value is negative → exp check skipped → Ok.
  // With the fix parseLong returns Err("overflow") → EXP_OVERFLOW.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTk5OTk5OTk5OTk5fQ.XSpwX_lbCxe7CP2z2kBxvBf7Hm-l14y_8YcA2UHqcdc",
    "test-secret",
    "",
    "",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "EXP_OVERFLOW", "20-digit exp → EXP_OVERFLOW (parseLong overflow → typed error code)")
}

test "nbf overflow regression: validly-signed token with 20-digit nbf is rejected (#1078)" {
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJuYmYiOjk5OTk5OTk5OTk5OTk5OTk5OTk5fQ.wfVtcqqLpXnI_yfTav0k0p4g1b8wsvJPPJ9x94JEkjA",
    "test-secret",
    "",
    "",
    "HS256"
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "NBF_OVERFLOW", "20-digit nbf → NBF_OVERFLOW")
}

// ─── #1089: RFC 7519 §4.1.3 array-form aud ────────────────────────────────────
test "verifyJwt: array-form aud containing expected audience verifies (#1089)" {
  // Payload: {"aud":["api.example.com","admin"]}, signed with HMAC-SHA256("test-secret").
  // Token reconstruction documented in the Python snippet above.
  val r = Auth.verifyJwt(
    "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOlsiYXBpLmV4YW1wbGUuY29tIiwiYWRtaW4iXX0.MaU1v7iUF4ZuurYpCTzGSeJQaGpj-PgemuvBvUZUwJE",
    "test-secret",
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
    "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOlsiYXBpLmV4YW1wbGUuY29tIiwiYWRtaW4iXX0.MaU1v7iUF4ZuurYpCTzGSeJQaGpj-PgemuvBvUZUwJE",
    "test-secret",
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
    "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJhcGkuZXhhbXBsZS5jb20ifQ.IO4WPTpwyrGklp1bW9Gnu_ETf8-b-PMSxkT_OKctPnc",
    "test-secret",
    "",
    "api.example.com",
    "HS256"
  )
  val isOk = match r { case Ok(v) -> true; case Err(e) -> false }
  assertTrue(isOk, "single-string aud match must continue to verify")
}

// ─── #1079: JSON escape decoding in claim values ─────────────────────────────
// extractClaim must decode standard JSON escape sequences in the claim value.
// Before #1079 a `sub` claim of `"O\"Brien"` was returned as the literal bytes
// `O\"Brien` (with the backslash), and `"line1\nline2"` was returned with a
// literal `\n` rather than a real newline.
test "extractClaim: claim value with escaped quote is decoded (#1079)" {
  // Payload: {"sub":"O\"Brien"} (after JSON unescaping it is O"Brien).
  // Signed with HMAC-SHA256("test-secret").
  val token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJPXCJCcmllbiJ9.0nB7w7b6e6YyAFrSNy7OjM2q26WIoSykU-cv0sw1xC0"
  // First confirm verification passes (so we know the payload is parsed).
  val v = Auth.verifyJwt(token, "test-secret", "", "", "HS256")
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
  val token = "eyJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJhbGljZSJ9.5aKgRbW0s3yamkNfocjRYD-wgC2m6fedIAg2c6k8I1c"
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
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.ll37qi5BStXya0qqqwLHM0oKvWoHHZMdnStJSCMiyPM",
    "test-secret",
    "",
    "",
    "HS256",
    0
  )
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "EXPIRED", "exp in the past with zero skew → EXPIRED")
}

test "verifyJwtWithSkew: large skew widens the validity window (#1081)" {
  // Same exp=1 token; apply a 2_000_000_000-second skew (~63 years).  This
  // marks the token as valid because nowSec - exp < skew.  Capped at
  // 2_000_000_000 (< Int.MaxValue = 2_147_483_647) so the literal fits in
  // an Int parameter without overflow (#1149).
  val r = Auth.verifyJwtWithSkew(
    "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjF9.ll37qi5BStXya0qqqwLHM0oKvWoHHZMdnStJSCMiyPM",
    "test-secret",
    "",
    "",
    "HS256",
    2000000000
  )
  val isOk = match r { case Ok(v) -> true; case Err(e) -> false }
  assertTrue(isOk, "exp=1 with absurdly large skew must verify (window widened)")
}

// ─── #1090: ALG_UNSUPPORTED vs ALG_REJECTED ──────────────────────────────────
// When the caller allow-lists an algorithm the kernel does not implement
// (e.g. RS256 on the .NET kernel today, #443), we surface ALG_UNSUPPORTED
// rather than masking it as BAD_SIGNATURE.
test "verifyJwt: alg allowed but unsupported by kernel returns ALG_UNSUPPORTED (#1090)" {
  // Token alg = RS256, caller allows RS256, but the .NET kernel only
  // implements HS256.  Surface this as ALG_UNSUPPORTED so operators see
  // the kernel limitation in logs instead of a generic verification failure.
  val r = Auth.verifyJwt("eyJhbGciOiJSUzI1NiJ9.payload.fakesig", "test-secret", "", "", "RS256")
  val code = match r { case Ok(v) -> "OK"; case Err(e) -> e.code }
  assertEqual(code, "ALG_UNSUPPORTED", "alg-allowed-but-not-implemented → ALG_UNSUPPORTED (not BAD_SIGNATURE)")
}
