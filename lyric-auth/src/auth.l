//! Auth — transport-agnostic authentication and credential verification.
//!
//! Stability: @stable(since="0.1") — public API covered by the
//! SemVer guarantee.  Per-function annotations track the same scope.
//!
//! Provides JWT, API-key, and role-claim primitives that work across HTTP,
//! gRPC, WebSockets, message queues, and CLI tools.  Protocol-specific
//! aspect *bindings* call these functions; the verification logic itself has
//! no transport dependency.
//!
//! Functions:
//!   Auth.verifyJwt          — validates a Bearer token against an explicit
//!                             allow-list of `alg` values (HS256, RS256, etc.).
//!                             Algorithm pinning prevents alg=none forgery and
//!                             HS256/RS256 confusion (RFC 8725 §3.1).  Returns
//!                             a typed Result so callers can distinguish
//!                             algorithm rejection from signature failure
//!                             (#1090).  Applies a 60-second clock-skew
//!                             leeway by default (#1081).
//!   Auth.verifyJwtWithSkew  — same as verifyJwt but with an explicit
//!                             `clockSkewSeconds` argument.
//!   Auth.extractClaim       — reads a named claim from a pre-verified JWT
//!   Auth.verifyApiKey       — constant-time comparison; prevents timing attacks
//!
//! Typical usage from a protocol binding (e.g. Web.Aspects.RequiresAuth):
//!
//!   match Auth.verifyJwt(token, jwtSecret, issuer, audience, "HS256") {
//!     case Ok(_)        -> ()  // proceed
//!     case Err(jwtErr)  -> return Err(Web.forbidden(jwtErr.message))
//!   }
//!   val role = Auth.extractClaim(token, "role")
//!
//! See lyric-web/src/aspects.l for the HTTP bindings (RequiresAuth,
//! RequiresRole, ApiKey).
@runtime_checked
package Auth

import Std.Core
import Std.Encoding
import Std.String
import Auth.Kernel.Net as AuthKernelNet
import Auth.Kernel.Jvm as AuthKernelJvm

// ─── JwtError (#1090) ─────────────────────────────────────────────────────────
/// Structured error returned by `verifyJwt` and `verifyJwtWithSkew`.
///
/// `code` is a stable, machine-readable identifier suitable for logs and
/// metrics; `message` is a human-readable description that does NOT include
/// any token contents.
///
/// Defined codes:
///   "MALFORMED_TOKEN"      — token did not have header.payload.signature shape
///   "MALFORMED_HEADER"     — header base64url/UTF-8/JSON parse failed
///   "ALG_REJECTED"         — token alg not in allowedAlgorithms
///   "ALG_UNSUPPORTED"      — token alg allowed by caller but not implemented
///                            in this build (e.g. RS256 on the .NET kernel
///                            until #443 lands)
///   "BAD_SIGNATURE"        — signature did not verify under secret
///   "MALFORMED_PAYLOAD"    — payload base64url/UTF-8/JSON parse failed
///   "ISSUER_MISMATCH"      — iss claim did not match expected issuer
///   "AUDIENCE_MISMATCH"    — aud claim did not match expected audience
///   "EXP_OVERFLOW"         — exp claim present but malformed/overflowed
///   "EXPIRED"              — exp in the past (beyond clockSkewSeconds)
///   "NBF_OVERFLOW"         — nbf claim present but malformed/overflowed
///   "NOT_YET_VALID"        — nbf in the future (beyond clockSkewSeconds)
///   "VERIFICATION_FAILED"  — JVM-only: any failure mode (JJWT does not
///                            surface fine-grained categories; tracked in #443)
@stable(since = "0.1")
pub record JwtError {
  code: String
  message: String
}

/// Default clock-skew leeway in seconds.  60 seconds matches industry
/// standard (Auth0, AWS Cognito, etc.) — large enough to absorb minor
/// NTP drift between issuer and validator, small enough to keep tokens
/// from outliving their declared expiry by a meaningful amount.  See
/// RFC 7519 §4.1.4 ("Implementers MAY provide for some small leeway,
/// usually no more than a few minutes, to account for clock skew").
@stable(since = "0.1")
pub func defaultClockSkewSeconds(): Int {
  60
}

// Map an error code returned by the kernel to a JwtError with a
// human-readable message.  Kept in sync with the codes documented above.
func makeJwtError(code: in String): JwtError {
  val msg = if code == "MALFORMED_TOKEN" {
    "JWT is malformed (expected header.payload.signature)"
  } else if code == "MALFORMED_HEADER" {
    "JWT header could not be decoded as base64url JSON"
  } else if code == "ALG_REJECTED" {
    "algorithm not permitted by allowedAlgorithms"
  } else if code == "ALG_UNSUPPORTED" {
    "algorithm is not implemented by this build (see #443)"
  } else if code == "BAD_SIGNATURE" {
    "JWT signature did not verify"
  } else if code == "MALFORMED_PAYLOAD" {
    "JWT payload could not be decoded as base64url JSON"
  } else if code == "ISSUER_MISMATCH" {
    "JWT iss claim did not match expected issuer"
  } else if code == "AUDIENCE_MISMATCH" {
    "JWT aud claim did not contain expected audience"
  } else if code == "EXP_OVERFLOW" {
    "JWT exp claim is malformed or overflows"
  } else if code == "EXPIRED" {
    "JWT has expired"
  } else if code == "NBF_OVERFLOW" {
    "JWT nbf claim is malformed or overflows"
  } else if code == "NOT_YET_VALID" {
    "JWT is not yet valid (nbf is in the future)"
  } else if code == "VERIFICATION_FAILED" {
    "JWT verification failed"
  } else {
    "JWT verification failed: " + code
  }
  JwtError(code = code, message = msg)
}

// ─── JWT algorithm extraction (Lyric-level, no extern dependency) ─────────────
// Find the first occurrence of `ch` in `s` at or after position `pos`.
// Returns -1 if not found.
func indexOfCharAfter(s: in String, ch: in Char, pos: in Int): Int {
  var i = pos
  while i < s.length {
    if s[i] == ch {
      return i
    }
    i = i + 1
  }
  return -1
}

// Extract the `alg` value from a JWT's base64url-encoded header segment.
// Returns "" when the token is malformed or the `alg` key is absent.
// Uses pure-Lyric base64url decode so no extern is needed — this function
// provides belt-and-suspenders algorithm enforcement at the Lyric layer in
// case the host shim has not yet wired `allowedAlgorithms` to the BCL
// validator's `ValidAlgorithms` list (see lyric-lang #443).
func jwtAlg(token: in String): String {
  // JWT format: base64url(header).base64url(payload).signature
  val dot = token.indexOf(".")
  if dot < 0 {
    return ""
  }
  // Convert base64url to standard base64: - → + and _ → /
  val seg = token.substring(0, dot)
  val std64 = seg.replace("-", "+").replace("_", "/")
  // Add '=' padding so length is a multiple of 4.
  val rem = std64.length % 4
  val padded = if rem == 0 { std64 } else if rem == 2 { std64 + "==" } else if rem == 3 { std64 + "=" } else { "" }
  // rem == 1 is not valid base64url
  if padded == "" {
    return ""
  }
  // Decode to bytes then to a UTF-8 string.
  match tryDecodeBase64(padded) {
    case None -> return ""
    case Some(bytes) -> {
      match tryDecodeUtf8(bytes) {
        case None -> return ""
        case Some(header) -> {
          // Scan for the "alg":"VALUE" key-value pair in the header JSON.
          // Use lastIndexOf so duplicate alg keys resolve to the last occurrence,
          // matching last-wins parser semantics (RFC 8259 §4 permits duplicates;
          // many JWT libraries use the last value).  This prevents a crafted first
          // alg=RS256 from masking a final alg=none in the same header.
          val pfx = "\"alg\":\""
          val pfxPos = header.lastIndexOf(pfx)
          if pfxPos < 0 {
            return ""
          }
          val vs = pfxPos + pfx.length
          val ve = indexOfCharAfter(header, '"', vs)
          if ve < 0 {
            return ""
          }
          header.substring(vs, ve - vs)
        }
      }
    }
  }
}

// ─── JWT verification ─────────────────────────────────────────────────────────
/// Validate a Bearer JWT with the default 60-second clock-skew leeway.
///
/// SECURITY: `allowedAlgorithms` MUST be a non-empty, comma-separated
/// allow-list of JWT `alg` values that the caller is prepared to honour
/// (e.g. `"HS256"` or `"HS256,RS256"`).  Tokens whose `alg` header is
/// `"none"` or any algorithm not in the list fail verification regardless
/// of signature content.  Without this allow-list a malicious client can
/// forge an unsigned `alg=none` token or pull off a classic HS256/RS256
/// confusion attack (signing with a known public key as the HMAC secret).
///
/// Returns:
///   Ok(())             — token is well-formed, signed correctly, and all
///                        present iss/aud/exp/nbf claims hold (with a
///                        60-second leeway around exp and nbf).
///   Err(JwtError(...)) — typed failure; see `JwtError` for the defined
///                        codes (`ALG_REJECTED`, `BAD_SIGNATURE`,
///                        `EXPIRED`, …).  Callers can branch on `code`
///                        to distinguish algorithm rejection from
///                        cryptographic failure from expiry, but should
///                        treat all `Err` variants as "deny" for the
///                        protected resource (#1090).
///
/// For configurable clock-skew leeway, see `verifyJwtWithSkew` (#1081).
///
/// Reference: RFC 8725 §3.1 (JWT Best Current Practices — algorithm
/// pinning); RFC 7519 §4.1.4 (clock-skew leeway).
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func verifyJwt(
  token: in String,
  secret: in String,
  issuer: in String,
  audience: in String,
  allowedAlgorithms: in String,
): Result[Unit, JwtError]
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
  // Case-insensitive check: catches "None", "NONE", "nOnE", etc.
  requires: not contains(toLower(allowedAlgorithms), "none")
{
  verifyJwtWithSkew(token, secret, issuer, audience, allowedAlgorithms, defaultClockSkewSeconds())
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func verifyJwt(
  token: in String,
  secret: in String,
  issuer: in String,
  audience: in String,
  allowedAlgorithms: in String,
): Result[Unit, JwtError]
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
  requires: not contains(toLower(allowedAlgorithms), "none")
{
  verifyJwtWithSkew(token, secret, issuer, audience, allowedAlgorithms, defaultClockSkewSeconds())
}

/// Validate a Bearer JWT with an explicit `clockSkewSeconds` leeway.
///
/// `clockSkewSeconds` widens the validity window symmetrically:
///   * token valid if `exp + clockSkewSeconds >= nowSec` (allows tokens
///     that just expired)
///   * token valid if `nbf - clockSkewSeconds <= nowSec` (allows tokens
///     whose `nbf` is slightly in the future relative to the verifier).
///
/// Pass `0` to enforce strict expiry (no leeway).  Pass `60` (the
/// `defaultClockSkewSeconds()` value) for the standard industry default.
/// Production callers should typically use `verifyJwt` and accept the
/// default; this entry point exists for testing and for callers with
/// stricter or more permissive operational requirements (#1081).
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func verifyJwtWithSkew(
  token: in String,
  secret: in String,
  issuer: in String,
  audience: in String,
  allowedAlgorithms: in String,
  clockSkewSeconds: in Int,
): Result[Unit, JwtError]
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
  // Case-insensitive check: catches "None", "NONE", "nOnE", etc.
  requires: not contains(toLower(allowedAlgorithms), "none")
  requires: clockSkewSeconds >= 0
{
  // Lyric-level algorithm pinning: reject before reaching the extern if the
  // token's `alg` header is not in `allowedAlgorithms`.  Guards against host
  // shims that have not yet wired `allowedAlgorithms` into the BCL validator's
  // `ValidAlgorithms` restriction (RFC 8725 §3.1; see lyric-lang #443).
  val alg = jwtAlg(token)
  if alg.length == 0 {
    // Malformed token (no header or header.alg missing) — surface this as
    // a structural failure rather than the kernel's BAD_SIGNATURE.
    return Err(makeJwtError("MALFORMED_HEADER"))
  }
  if not rolesContain(allowedAlgorithms, alg) {
    return Err(makeJwtError("ALG_REJECTED"))
  }
  match AuthKernelNet.verifyJwtImpl(token, secret, issuer, audience, allowedAlgorithms, clockSkewSeconds) {
    case Ok(unit) -> Ok(())
    case Err(code) -> Err(makeJwtError(code))
  }
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func verifyJwtWithSkew(
  token: in String,
  secret: in String,
  issuer: in String,
  audience: in String,
  allowedAlgorithms: in String,
  clockSkewSeconds: in Int,
): Result[Unit, JwtError]
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
  // Case-insensitive check: catches "None", "NONE", "nOnE", etc.
  requires: not contains(toLower(allowedAlgorithms), "none")
  requires: clockSkewSeconds >= 0
{
  // Lyric-level algorithm pinning: same guard as the .NET overload above.
  val alg = jwtAlg(token)
  if alg.length == 0 {
    return Err(makeJwtError("MALFORMED_HEADER"))
  }
  if not rolesContain(allowedAlgorithms, alg) {
    return Err(makeJwtError("ALG_REJECTED"))
  }
  match AuthKernelJvm.verifyJwtImpl(token, secret, issuer, audience, allowedAlgorithms, clockSkewSeconds) {
    case Ok(unit) -> Ok(())
    case Err(code) -> Err(makeJwtError(code))
  }
}

// ─── Claim extraction ─────────────────────────────────────────────────────────
/// Extract a named claim from a JWT payload.
///
/// Call this ONLY on tokens already accepted by `verifyJwt`.  The function
/// does not re-verify the signature; it decodes the payload and returns the
/// value for `claimKey`, or None if the claim is absent.
///
/// Common claim keys: "sub" (subject), "role", "email", "scope".
///
/// Claim values containing JSON escape sequences (`\"`, `\n`, `\uXXXX`) are
/// decoded to their actual character contents (#1079).
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func extractClaim(token: in String, claimKey: in String): Option[String]
  requires: claimKey.length > 0
{
  return AuthKernelNet.extractClaimImpl(token, claimKey)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func extractClaim(token: in String, claimKey: in String): Option[String]
  requires: claimKey.length > 0
{
  return AuthKernelJvm.extractClaim(token, claimKey)
}

// ─── API key verification ─────────────────────────────────────────────────────
/// Byte-content-constant-time comparison of `provided` against `expected`.
///
/// Returns true iff the two strings are byte-for-byte identical.  The
/// comparison is constant-time with respect to content when both encode to
/// the same byte length, preventing value-oracle timing attacks.  When
/// lengths differ the call returns immediately; for fixed-format keys
/// (e.g. 32-byte random tokens) the length is not secret and this is
/// acceptable.
///
/// Always supply the expected key as `expected` (not `provided`) to keep
/// the length-constant guarantee aligned with the fixed expected key.
@stable(since = "0.1")
@cfg(feature = "dotnet")
pub func verifyApiKey(provided: in String, expected: in String): Bool
  requires: expected.length > 0
{
  return AuthKernelNet.verifyApiKeyImpl(provided, expected)
}

@stable(since = "0.1")
@cfg(feature = "jvm")
pub func verifyApiKey(provided: in String, expected: in String): Bool
  requires: expected.length > 0
{
  return AuthKernelJvm.verifyApiKey(provided, expected)
}

// ─── Role claim helpers ───────────────────────────────────────────────────────
/// Check whether a comma-separated role string contains `role`.
///
/// Used by RequiresRole bindings to match the `role` JWT claim against
/// an allowlist.  For example, `"admin,manager"` contains `"admin"`.
/// Whitespace around each comma-separated entry is trimmed before
/// comparison, so `"admin, manager"` matches `"manager"`.  Empty
/// entries (e.g. `",,"` or `"admin,"`) never match.
///
/// Security note: `role` is compared as-is without trimming.  JWT claim
/// values are compact by specification, so trimming `role` would silently
/// loosen matching — a JWT claim of `"admin "` (trailing space) would
/// match `"admin"`, which is a security regression.  Only entries in
/// `allowedRoles` (caller-controlled) are trimmed for convenience.
@stable(since = "0.1")
pub func rolesContain(allowedRoles: in String, role: in String): Bool {
  if allowedRoles.length == 0 {
    return false
  }
  if role.length == 0 {
    return false
  }
  // Simple linear scan — role lists are short; no allocation needed.
  var start: Int = 0
  var i: Int = 0
  while i <= allowedRoles.length {
    val atEnd = i == allowedRoles.length
    val atComma = not atEnd and (allowedRoles[i] == ',')
    if atEnd or atComma {
      val candidate = allowedRoles.substring(start, i - start).trim()
      if candidate.length > 0 and candidate == role {
        return true
      }
      start = i + 1
    }
    i = i + 1
  }
  return false
}
