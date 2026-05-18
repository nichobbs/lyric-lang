/// Auth — transport-agnostic authentication and credential verification.
///
/// Provides JWT, API-key, and role-claim primitives that work across HTTP,
/// gRPC, WebSockets, message queues, and CLI tools.  Protocol-specific
/// aspect *bindings* call these functions; the verification logic itself has
/// no transport dependency.
///
/// Functions:
///   Auth.verifyJwt      — validates a Bearer token against an explicit
///                         allow-list of `alg` values (HS256, RS256, etc.).
///                         Algorithm pinning prevents alg=none forgery and
///                         HS256/RS256 confusion (RFC 8725 §3.1).
///   Auth.extractClaim   — reads a named claim from a pre-verified JWT
///   Auth.verifyApiKey   — constant-time comparison; prevents timing attacks
///
/// Typical usage from a protocol binding (e.g. Web.Aspects.RequiresAuth):
///
///   val ok = Auth.verifyJwt(token, jwtSecret, issuer, audience, "HS256")
///   if not ok { return Err(Web.forbidden("Token is invalid")) }
///   val role = Auth.extractClaim(token, "role")
///
/// See lyric-web/src/aspects.l for the HTTP bindings (RequiresAuth,
/// RequiresRole, ApiKey).

@runtime_checked
package Auth

import Std.Core
import Std.Encoding
import Auth.Kernel.Net
import Auth.Kernel.Jvm

// ─── JWT algorithm extraction (Lyric-level, no extern dependency) ─────────────

// Find the first occurrence of `ch` in `s` at or after position `pos`.
// Returns -1 if not found.
func indexOfCharAfter(s: in String, ch: in String, pos: in Int): Int {
  var i = pos
  while i < s.length {
    if s.charAt(i).toString() == ch { return i }
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
  if dot < 0 { return "" }
  // Convert base64url to standard base64: - → + and _ → /
  val seg   = token.substring(0, dot)
  val std64 = seg.replace("-", "+").replace("_", "/")
  // Add '=' padding so length is a multiple of 4.
  val rem = std64.length % 4
  val padded =
    if rem == 0 { std64 }
    else if rem == 2 { std64 + "==" }
    else if rem == 3 { std64 + "=" }
    else { "" }  // rem == 1 is not valid base64url
  if padded == "" { return "" }
  // Decode to bytes then to a UTF-8 string.
  match Std.Encoding.tryDecodeBase64(padded) {
    case None -> return ""
    case Some(bytes) -> {
      match Std.Encoding.tryDecodeUtf8(bytes) {
        case None -> return ""
        case Some(header) -> {
          // Scan for the "alg":"VALUE" key-value pair in the header JSON.
          // Use lastIndexOf so duplicate alg keys resolve to the last occurrence,
          // matching last-wins parser semantics (RFC 8259 §4 permits duplicates;
          // many JWT libraries use the last value).  This prevents a crafted first
          // alg=RS256 from masking a final alg=none in the same header.
          val pfx    = "\"alg\":\""
          val pfxPos = header.lastIndexOf(pfx)
          if pfxPos < 0 { return "" }
          val vs = pfxPos + pfx.length
          val ve = indexOfCharAfter(header, "\"", vs)
          if ve < 0 { return "" }
          header.substring(vs, ve)
        }
      }
    }
  }
}

// ─── JWT verification ─────────────────────────────────────────────────────────

/// Validate a Bearer JWT.
///
/// SECURITY: `allowedAlgorithms` MUST be a non-empty, comma-separated
/// allow-list of JWT `alg` values that the caller is prepared to honour
/// (e.g. `"HS256"` or `"HS256,RS256"`).  The kernel binds this list to
/// the underlying validator's algorithm restriction, so tokens whose
/// `alg` header is `"none"` or any algorithm not in the list fail
/// verification regardless of signature content.  Without this
/// allow-list a malicious client can forge an unsigned `alg=none` token
/// or pull off a classic HS256/RS256 confusion attack (signing with a
/// known public key as the HMAC secret).
///
/// Returns true iff:
///   - The token is syntactically well-formed.
///   - The `alg` header is contained in `allowedAlgorithms`.
///   - The signature verifies against `secret` under the declared `alg`.
///   - `issuer` matches the `iss` claim (skipped when `issuer` is empty).
///   - `audience` matches the `aud` claim (skipped when `audience` is empty).
///
/// Returns false for any failure — expired, tampered, missing claim,
/// `alg` not in allow-list, or malformed header.  False is the safe
/// default; callers must treat it as "deny" and never special-case
/// error variants.
///
/// Reference: RFC 8725 §3.1 (JWT Best Current Practices — algorithm
/// pinning).  See lyric-lang #315.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func verifyJwt(
  token:             in String,
  secret:            in String,
  issuer:            in String,
  audience:          in String,
  allowedAlgorithms: in String
): Bool
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
  requires: not Std.String.contains(allowedAlgorithms, "none")
{
  // Lyric-level algorithm pinning: reject before reaching the extern if the
  // token's `alg` header is not in `allowedAlgorithms`.  Guards against host
  // shims that have not yet wired `allowedAlgorithms` into the BCL validator's
  // `ValidAlgorithms` restriction (RFC 8725 §3.1; see lyric-lang #443).
  val alg = jwtAlg(token)
  if alg.length == 0 { return false }
  if not rolesContain(allowedAlgorithms, alg) { return false }
  return Auth.Kernel.Net.verifyJwt(token, secret, issuer, audience, allowedAlgorithms)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func verifyJwt(
  token:             in String,
  secret:            in String,
  issuer:            in String,
  audience:          in String,
  allowedAlgorithms: in String
): Bool
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
  requires: not Std.String.contains(allowedAlgorithms, "none")
{
  // Lyric-level algorithm pinning: same guard as the .NET overload above.
  val alg = jwtAlg(token)
  if alg.length == 0 { return false }
  if not rolesContain(allowedAlgorithms, alg) { return false }
  return Auth.Kernel.Jvm.verifyJwt(token, secret, issuer, audience, allowedAlgorithms)
}

// ─── Claim extraction ─────────────────────────────────────────────────────────

/// Extract a named claim from a JWT payload.
///
/// Call this ONLY on tokens already accepted by `verifyJwt`.  The function
/// does not re-verify the signature; it decodes the payload and returns the
/// value for `claimKey`, or None if the claim is absent.
///
/// Common claim keys: "sub" (subject), "role", "email", "scope".
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func extractClaim(token: in String, claimKey: in String): Option[String]
  requires: claimKey.length > 0
{
  return Auth.Kernel.Net.extractClaim(token, claimKey)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func extractClaim(token: in String, claimKey: in String): Option[String]
  requires: claimKey.length > 0
{
  return Auth.Kernel.Jvm.extractClaim(token, claimKey)
}

// ─── API key verification ─────────────────────────────────────────────────────

/// Constant-time comparison of `provided` against `expected`.
///
/// Returns true iff the two strings are byte-for-byte identical.
/// The comparison runs in time proportional to `expected.length` regardless
/// of where the strings first differ, preventing timing-oracle attacks.
///
/// Always supply the expected key as `expected` (not `provided`) to ensure
/// the timing guarantee holds even when `provided` is shorter.
@stable(since="0.1")
@cfg(feature = "dotnet")
pub func verifyApiKey(provided: in String, expected: in String): Bool
  requires: expected.length > 0
{
  return Auth.Kernel.Net.verifyApiKey(provided, expected)
}

@stable(since="0.1")
@cfg(feature = "jvm")
pub func verifyApiKey(provided: in String, expected: in String): Bool
  requires: expected.length > 0
{
  return Auth.Kernel.Jvm.verifyApiKey(provided, expected)
}

// ─── Role claim helpers ───────────────────────────────────────────────────────

/// Check whether a comma-separated role string contains `role`.
///
/// Used by RequiresRole bindings to match the `role` JWT claim against
/// an allowlist.  For example, `"admin,manager"` contains `"admin"`.
/// Whitespace around each comma-separated entry in `allowedRoles` is trimmed
/// before comparison, so `"admin, manager"` matches `"manager"`.  Empty entries
/// (e.g. `",,"` or `"admin,"`) never match.
///
/// Note: `role` is compared as-is (no trimming).  JWT claim values are compact
/// by specification, so trimming `role` would silently loosen matching and could
/// become a security regression in future refactors.
@stable(since="0.1")
pub func rolesContain(allowedRoles: in String, role: in String): Bool {
  if allowedRoles.length == 0 { return false }
  if role.length == 0         { return false }
  // Simple linear scan — role lists are short; no allocation needed.
  var start: Int = 0
  var i:     Int = 0
  while i <= allowedRoles.length {
    val atEnd     = i == allowedRoles.length
    val atComma   = not atEnd && allowedRoles.charAt(i).toString() == ","
    if atEnd || atComma {
      val candidate = allowedRoles.substring(start, i).trim()
      if candidate.length > 0 && candidate == role { return true }
      start = i + 1
    }
    i = i + 1
  }
  return false
}
