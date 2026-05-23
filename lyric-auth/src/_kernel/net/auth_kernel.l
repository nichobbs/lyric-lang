// Auth.Kernel.Net — .NET authentication extern boundary.
//
// Bridges Auth's verification functions to BCL crypto primitives via the
// `Lyric.Auth.AuthHost` host shim (bootstrap/src/Lyric.Auth.Host/).
//
// The host shim exposes exactly two BCL-bound operations:
//
//   hmacSha256       — HMAC-SHA256 signature computation (HMACSHA256.ComputeHash)
//   fixedTimeEquals  — byte-content-constant-time comparison (FixedTimeEquals)
//
// All other JWT logic — base64url decoding, JSON claim scanning, exp/nbf
// validation, algorithm allow-list enforcement, and API-key byte comparison —
// is implemented here in Lyric so that only the truly BCL-bound operations
// cross the extern boundary.
//
// Algorithm support:
//   HS256 — BCL HMAC-SHA256 (no NuGet dependency).
//   RS256 and other public-key algorithms — fail closed (return false).
//   Full `System.IdentityModel.Tokens.Jwt` integration tracked in #443.
//
// Only active when compiled with feature = "dotnet".
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Auth.Kernel.Net

import Std.Core
import Std.Encoding
import Std.String
import Std.Char
import Std.Time

// ─── BCL extern boundary ─────────────────────────────────────────────────────

/// Compute HMAC-SHA256 of `message` using `key`.
/// Returns the raw 32-byte MAC as a byte array.
@axiom("Lyric.Auth.AuthHost.hmacSha256 — BCL HMACSHA256.ComputeHash")
@externTarget("Lyric.Auth.AuthHost.hmacSha256")
@stable(since="0.1")
func hmacSha256(key: in slice[Byte], message: in slice[Byte]): slice[Byte]
  requires: key.length > 0
  = ()

/// Byte-content-constant-time comparison of `a` and `b`.
/// Constant-time for equal-length inputs; returns immediately on length mismatch.
@axiom("Lyric.Auth.AuthHost.fixedTimeEquals — CryptographicOperations.FixedTimeEquals")
@externTarget("Lyric.Auth.AuthHost.fixedTimeEquals")
@stable(since="0.1")
func fixedTimeEqualBytes(a: in slice[Byte], b: in slice[Byte]): Bool
  = ()

// ─── Base64url decoding ───────────────────────────────────────────────────────

// Decode a base64url segment (no padding) to raw bytes.
// Returns None for invalid base64 input, including rem==1 which is not valid
// base64url.
func fromBase64Url(seg: in String): Option[slice[Byte]] {
  val std64 = seg.replace("-", "+").replace("_", "/")
  val rem = std64.length % 4
  val padded =
    if rem == 0 { std64 }
    else if rem == 2 { std64 + "==" }
    else if rem == 3 { std64 + "=" }
    else { "" }
  if padded.length == 0 { return None }
  tryDecodeBase64(padded)
}

// ─── JSON claim scanning ──────────────────────────────────────────────────────

// Extract a string-valued claim from a JSON object string.
// Scans for `"key":"VALUE"` using lastIndexOf for last-wins duplicate-key
// semantics (RFC 8259 §4; matches most JWT library parsers).
// Returns "" when the key is absent or the JSON is malformed.
func getStringClaimFromJson(json: in String, key: in String): String {
  val pfx = "\"" + key + "\":\""
  val pfxPos = json.lastIndexOf(pfx)
  if pfxPos < 0 { return "" }
  val vs = pfxPos + pfx.length
  var ve = vs
  while ve < json.length and json[ve] != '"' {
    ve = ve + 1
  }
  if ve >= json.length { return "" }
  // Use standalone substring with explicit COUNT to satisfy the requires contract.
  val count = ve - vs
  if count == 0 { return "" }
  substring(json, vs, count)
}

// Extract a string claim from a UTF-8-encoded payload byte slice.
// Returns "" when decoding fails or the claim is absent.
func getStringClaim(payloadBytes: in slice[Byte], key: in String): String {
  match tryDecodeUtf8(payloadBytes) {
    case None -> ""
    case Some(json) -> getStringClaimFromJson(json, key)
  }
}

// Parse a non-negative decimal integer string to Long.
// Returns -1i64 for empty input, any non-digit character, or inputs longer than
// 18 digits (Long.MaxValue has 19 digits; capping at 18 prevents unchecked
// integer overflow from turning a large-but-present exp/nbf claim into a
// negative value that silently bypasses the expiry check — #1078).
func parseLong(s: in String): Long {
  if s.length == 0  { return -1i64 }
  if s.length > 18  { return -1i64 }
  var result: Long = 0i64
  var i = 0
  while i < s.length {
    if not isDigit(s[i]) { return -1i64 }
    val d = toInt(s[i]) - toInt('0')
    result = result * 10i64 + d
    i = i + 1
  }
  result
}

// Extract a numeric (integer) claim from a JSON object string.
// Scans for `"key":NUMBER` using lastIndexOf for last-wins duplicate-key
// semantics.
//
// Return convention:
//   -1i64  — key absent (caller should skip the claim check)
//   -2i64  — key present but value is malformed or overflows Long (caller must
//             REJECT the token — skipping the check on a present-but-unparseable
//             claim would silently bypass exp/nbf enforcement, #1078)
//   >= 0   — key present and value successfully parsed
func getLongClaimFromJson(json: in String, key: in String): Long {
  val pfx = "\"" + key + "\":"
  val pfxPos = json.lastIndexOf(pfx)
  if pfxPos < 0 { return -1i64 }
  var vs = pfxPos + pfx.length
  // Skip any whitespace between ':' and the number.
  while vs < json.length and json[vs] == ' ' {
    vs = vs + 1
  }
  // Key is present; any parse failure from here is -2i64, not -1i64.
  if vs >= json.length { return -2i64 }
  if not isDigit(json[vs]) { return -2i64 }
  var ve = vs
  while ve < json.length and isDigit(json[ve]) {
    ve = ve + 1
  }
  val count = ve - vs
  if count == 0 { return -2i64 }
  val numStr = substring(json, vs, count)
  val parsed = parseLong(numStr)
  if parsed < 0i64 { return -2i64 }
  parsed
}

// ─── Algorithm allow-list ─────────────────────────────────────────────────────

// Check whether a comma-separated algorithm list contains `alg`.
// Whitespace around each entry is trimmed.  Empty entries never match.
func algListContains(list: in String, alg: in String): Bool {
  if list.length == 0 { return false }
  if alg.length == 0  { return false }
  var start: Int = 0
  var i:     Int = 0
  while i <= list.length {
    val atEnd   = i == list.length
    val atComma = not atEnd and list[i] == ','
    if atEnd or atComma {
      val count = i - start
      if count > 0 {
        val candidate = trim(substring(list, start, count))
        if candidate == alg { return true }
      }
      start = i + 1
    }
    i = i + 1
  }
  false
}

// ─── JWT header alg extraction ────────────────────────────────────────────────

// Decode the base64url JWT header segment and return the `alg` claim value.
// Returns "" on any decode or parse failure.
func jwtAlgFromHeader(headerSeg: in String): String {
  match fromBase64Url(headerSeg) {
    case None -> ""
    case Some(headerBytes) -> {
      match tryDecodeUtf8(headerBytes) {
        case None -> ""
        case Some(headerJson) -> getStringClaimFromJson(headerJson, "alg")
      }
    }
  }
}

// ─── JWT payload claim validation ────────────────────────────────────────────

// Decode the base64url JWT payload segment and validate iss, aud, exp, and nbf
// claims.  Returns false if the payload cannot be decoded, or if any present
// claim fails its check.  Returns true when all present claims are valid.
func validatePayload(
  payloadSeg: in String,
  issuer:     in String,
  audience:   in String
): Bool {
  match fromBase64Url(payloadSeg) {
    case None -> false
    case Some(payloadBytes) -> {
      match tryDecodeUtf8(payloadBytes) {
        case None -> false
        case Some(payloadJson) -> {
          // Capture the current time once for consistent exp/nbf evaluation.
          val nowSec: Long = nowEpochMillis() / 1000i64
          // Validate iss claim when the caller supplied a non-empty issuer.
          if issuer.length > 0 {
            val iss = getStringClaimFromJson(payloadJson, "iss")
            if iss != issuer { return false }
          }
          // Validate aud claim when the caller supplied a non-empty audience.
          if audience.length > 0 {
            val aud = getStringClaimFromJson(payloadJson, "aud")
            if aud != audience { return false }
          }
          // Validate exp: token must not be expired.
          // -2i64 means present but malformed — reject immediately (#1078).
          val exp = getLongClaimFromJson(payloadJson, "exp")
          if exp < -1i64 { return false }
          if exp >= 0i64 and nowSec > exp { return false }
          // Validate nbf: token must not be used before it becomes valid.
          // -2i64 means present but malformed — reject immediately (#1078).
          val nbf = getLongClaimFromJson(payloadJson, "nbf")
          if nbf < -1i64 { return false }
          if nbf >= 0i64 and nowSec < nbf { return false }
          true
        }
      }
    }
  }
}

// ─── JWT verification ─────────────────────────────────────────────────────────

/// Validate a Bearer JWT against an explicit allow-list of algorithms.
///
/// This kernel enforces that the token's `alg` header is `"HS256"`, since
/// HS256 is the only algorithm supported by the BCL extern boundary.  RS256
/// and other public-key algorithms fail closed (return false); full public-key
/// support is tracked in #443.
///
/// `exp` and `nbf` claims are validated when present.  A token with an `exp`
/// in the past or an `nbf` in the future fails verification.
///
/// Returns true iff the token is well-formed, its HMAC-SHA256 signature
/// verifies against `secret`, and — when non-empty — the `iss` and `aud`
/// claims match.
@stable(since="0.1")
pub func verifyJwt(
  token:             in String,
  secret:            in String,
  issuer:            in String,
  audience:          in String,
  allowedAlgorithms: in String
): Bool
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
{
  // Split into header.payload.signature — must be exactly three parts.
  val parts = split(token, ".")
  if parts.length != 3 { return false }

  // Verify algorithm: kernel supports HS256 only.
  val alg = jwtAlgFromHeader(parts[0])
  if alg != "HS256" { return false }
  // Belt-and-suspenders: HS256 must also appear in the caller's allow-list.
  if not algListContains(allowedAlgorithms, "HS256") { return false }

  // Verify HMAC-SHA256 signature over header.payload.
  val signingInput = parts[0] + "." + parts[1]
  val signingInputBytes = encodeUtf8(signingInput)
  val secretBytes = encodeUtf8(secret)
  val expectedSig = hmacSha256(secretBytes, signingInputBytes)
  match fromBase64Url(parts[2]) {
    case None -> return false
    case Some(providedSig) -> {
      if not fixedTimeEqualBytes(expectedSig, providedSig) { return false }
    }
  }

  // Validate payload claims (iss, aud, exp, nbf).
  return validatePayload(parts[1], issuer, audience)
}

// ─── Claim extraction ─────────────────────────────────────────────────────────

/// Try to extract a named string claim from a JWT payload segment.
/// Sets `value` to the claim string and returns true on success.
/// Returns false and leaves `value` unchanged for absent claims or malformed tokens.
/// Call only on tokens already accepted by verifyJwt.
@stable(since="0.1")
pub func tryExtractClaim(
  token:    in  String,
  claimKey: in  String,
  value:    out String
): Bool
  requires: claimKey.length > 0
{
  val parts = split(token, ".")
  if parts.length < 2 { return false }
  match fromBase64Url(parts[1]) {
    case None -> return false
    case Some(payloadBytes) -> {
      val claim = getStringClaim(payloadBytes, claimKey)
      if claim.length == 0 { return false }
      value = claim
      return true
    }
  }
  return false
}

/// Extract a named claim from a JWT payload without re-verifying the signature.
/// Call only on tokens already accepted by verifyJwt.
/// Returns None if the claim is absent or the token is malformed.
@stable(since="0.1")
pub func extractClaim(token: in String, claimKey: in String): Option[String]
  requires: claimKey.length > 0
{
  var v: String = ""
  if tryExtractClaim(token, claimKey, v) {
    return Some(v)
  }
  return None
}

// ─── API key verification ─────────────────────────────────────────────────────

/// Byte-content-constant-time comparison of `provided` against `expected`.
/// Returns true iff the two strings are byte-for-byte identical.
/// Constant-time with respect to content when both encode to the same byte
/// length, preventing value-oracle timing attacks.  Length mismatches exit
/// early; for fixed-format keys the length is not secret so this is acceptable.
@stable(since="0.1")
pub func verifyApiKey(provided: in String, expected: in String): Bool
  requires: expected.length > 0
{
  val a = encodeUtf8(provided)
  val b = encodeUtf8(expected)
  fixedTimeEqualBytes(a, b)
}
