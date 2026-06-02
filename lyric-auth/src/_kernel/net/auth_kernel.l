// Auth.Kernel.Net — .NET authentication extern boundary.
//
// Bridges Auth's verification functions to BCL crypto primitives with no
// host shim: the one remaining BCL-bound operation binds directly to a
// static method on a `System.Security.Cryptography` type, exactly as
// `Std.Hash` binds to `SHA512.HashData`.
//
//   hmacSha256          — HMAC-SHA256 signature computation, bound directly to
//                         `System.Security.Cryptography.HMACSHA256.HashData`.
//   fixedTimeEqualBytes — byte-content-constant-time comparison, implemented
//                         in pure Lyric (branchless XOR-accumulate; see below).
//                         Tracked in #1760 to rebind to the JIT-hardened
//                         `CryptographicOperations.FixedTimeEquals` once the
//                         emitter gains `ReadOnlySpan<byte>` extern support.
//
// All other JWT logic — base64url decoding, JSON claim scanning, exp/nbf
// validation, algorithm allow-list enforcement, and API-key byte comparison —
// is implemented here in Lyric so that only the truly BCL-bound operation
// crosses the extern boundary.
//
// Algorithm support:
//   HS256 — BCL HMAC-SHA256 (no NuGet dependency).
//   RS256 and other public-key algorithms — fail closed (Err("ALG_UNSUPPORTED")).
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
import Std.Math
import Std.Time

// ─── BCL extern boundary ─────────────────────────────────────────────────────

/// Compute HMAC-SHA256 of `message` using `key`.
/// Returns the raw 32-byte MAC as a byte array.
///
/// Binds directly to the BCL static `HMACSHA256.HashData(byte[] key,
/// byte[] source)` — the same direct-extern pattern as `Std.Hash`'s
/// `SHA512.HashData`, with no host shim.
@axiom("System.Security.Cryptography.HMACSHA256.HashData conforms to documented .NET HMAC-SHA256 semantics; it is a pure function of (key, message)")
@externTarget("System.Security.Cryptography.HMACSHA256.HashData")
@stable(since="0.1")
func hmacSha256(key: in slice[Byte], message: in slice[Byte]): slice[Byte]
  requires: key.length > 0
  = ()

/// Byte-content-constant-time comparison of `a` and `b`.
///
/// Branchless XOR-accumulate: every byte position is compared and the
/// differences are OR-folded into an accumulator, so the running time
/// depends only on the input length — never on the byte values or on the
/// position of the first mismatch. This is the portable constant-time
/// equality construction (cf. Go's `crypto/subtle.ConstantTimeCompare` and
/// libsodium's `sodium_memcmp` fallback).
///
/// Length is treated as non-secret: the function exits early on a length
/// mismatch. This matches the boundary's prior `FixedTimeEquals` semantics
/// (which documented the same property); for fixed-format secrets such as
/// HMAC tags and API keys the length is not sensitive.
///
/// #1760 tracks rebinding this to the JIT-hardened BCL
/// `CryptographicOperations.FixedTimeEquals` once the emitter supports
/// `ReadOnlySpan<byte>` extern parameters (the BCL method has no `byte[]`
/// overload, so the table-driven `@externTarget` resolver cannot encode it).
@stable(since="0.1")
func fixedTimeEqualBytes(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length { return false }
  var diff: Int = 0
  var i = 0
  while i < a.length {
    val ai: Int = 0 + a[i]
    val bi: Int = 0 + b[i]
    diff = diff.or(ai.xor(bi))
    i = i + 1
  }
  diff == 0
}

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

// ─── JSON string escape decoding (#1079) ─────────────────────────────────────

// Decode a single hex digit ('0'..'9', 'a'..'f', 'A'..'F') to its value 0..15.
// Returns -1 for non-hex input.
func hexDigit(c: in Char): Int {
  val cp = toInt(c)
  if cp >= 48 and cp <= 57  { return cp - 48 }  // '0'..'9'
  if cp >= 97 and cp <= 102 { return 10 + cp - 97 }  // 'a'..'f'
  if cp >= 65 and cp <= 70  { return 10 + cp - 65 }  // 'A'..'F'
  -1
}

// Append the UTF-8 encoding of a Unicode code point to `acc`.
// Returns the new accumulated string.  Code points within the BMP are emitted
// directly via Std.Char.fromInt; astral code points (>0xFFFF) are split into a
// UTF-16 surrogate pair (matching how Std.Encoding.tryDecodeUtf8 reconstructs
// 4-byte UTF-8 — see std/encoding.l).  Invalid inputs (outside Unicode range,
// lone surrogate) emit U+FFFD so the function is total.
func appendCodepoint(acc: in String, cp: in Int): String {
  if cp < 0 or cp > 1114111 or (cp >= 55296 and cp <= 57343) {
    // U+FFFD REPLACEMENT CHARACTER.
    return acc + "\u{FFFD}"
  }
  if cp <= 65535 {
    return acc + ("" + fromInt(cp))
  }
  // Astral plane: encode as UTF-16 surrogate pair.
  val cp1 = cp - 65536
  val high = 55296 + cp1 / 1024
  val low  = 56320 + cp1 % 1024
  acc + ("" + fromInt(high)) + ("" + fromInt(low))
}

// Decode JSON string escape sequences in `s` (RFC 8259 §7).
//
// Recognises all standard escapes:
//   \" \\ \/ \b \f \n \r \t  — single-char escapes
//   \uXXXX                    — basic multilingual plane
//   \uHHHH\uLLLL              — surrogate pair → astral code point
//
// Invalid escapes (unknown letter, short \uXXXX, lone surrogate) emit
// U+FFFD at the offending position so the function is total — callers do
// not have to handle a parse failure.  This matches `System.Text.Json`'s
// permissive-but-faithful behaviour for JWT payloads (which are
// machine-emitted and almost never carry malformed escapes).
func decodeJsonEscapes(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = s[i]
    if c != '\\' {
      acc = acc + substring(s, i, 1)
      i = i + 1
    } else {
      // c == '\\'.  Consume the escape sequence.
      if i + 1 >= s.length {
        // Dangling backslash at end of string — emit replacement.
        acc = acc + "\u{FFFD}"
        i = i + 1
      } else {
        val esc = s[i + 1]
        if esc == '"'      { acc = acc + "\""; i = i + 2 }
        else if esc == '\\' { acc = acc + "\\"; i = i + 2 }
        else if esc == '/'  { acc = acc + "/";  i = i + 2 }
        else if esc == 'b'  { acc = acc + "\u{08}"; i = i + 2 }
        else if esc == 'f'  { acc = acc + "\u{0C}"; i = i + 2 }
        else if esc == 'n'  { acc = acc + "\n"; i = i + 2 }
        else if esc == 'r'  { acc = acc + "\r"; i = i + 2 }
        else if esc == 't'  { acc = acc + "\t"; i = i + 2 }
        else if esc == 'u'  {
          // \uXXXX — need 4 hex digits.
          if i + 5 >= s.length {
            acc = acc + "\u{FFFD}"
            i = s.length
          } else {
            val h0 = hexDigit(s[i + 2])
            val h1 = hexDigit(s[i + 3])
            val h2 = hexDigit(s[i + 4])
            val h3 = hexDigit(s[i + 5])
            if h0 < 0 or h1 < 0 or h2 < 0 or h3 < 0 {
              acc = acc + "\u{FFFD}"
              i = i + 2  // skip past \u, retry on the bad nibble
            } else {
              val cp = (h0 * 4096) + (h1 * 256) + (h2 * 16) + h3
              // Handle surrogate pair for astral code points.
              // 0xD800 = 55296, 0xDBFF = 56319, 0xDC00 = 56320, 0xDFFF = 57343.
              if cp >= 55296 and cp <= 56319 {
                // High surrogate — expect \uLLLL low surrogate next.
                if i + 11 < s.length and s[i + 6] == '\\' and s[i + 7] == 'u' {
                  val l0 = hexDigit(s[i + 8])
                  val l1 = hexDigit(s[i + 9])
                  val l2 = hexDigit(s[i + 10])
                  val l3 = hexDigit(s[i + 11])
                  if l0 < 0 or l1 < 0 or l2 < 0 or l3 < 0 {
                    acc = acc + "\u{FFFD}"
                    i = i + 6
                  } else {
                    val lo = (l0 * 4096) + (l1 * 256) + (l2 * 16) + l3
                    if lo >= 56320 and lo <= 57343 {
                      // Combine surrogate pair to astral code point.
                      val combined = 65536 + ((cp - 55296) * 1024) + (lo - 56320)
                      acc = appendCodepoint(acc, combined)
                      i = i + 12
                    } else {
                      // Lone high surrogate — emit replacement, retry from low.
                      acc = acc + "\u{FFFD}"
                      i = i + 6
                    }
                  }
                } else {
                  acc = acc + "\u{FFFD}"
                  i = i + 6
                }
              } else if cp >= 56320 and cp <= 57343 {
                // Lone low surrogate — emit replacement.
                acc = acc + "\u{FFFD}"
                i = i + 6
              } else {
                acc = appendCodepoint(acc, cp)
                i = i + 6
              }
            }
          }
        } else {
          // Unknown escape — emit replacement, skip the backslash.
          acc = acc + "\u{FFFD}"
          i = i + 2
        }
      }
    }
  }
  acc
}

// ─── JSON claim scanning ──────────────────────────────────────────────────────

// Walk past a JSON-encoded string starting at the opening quote position
// `quotePos` (json[quotePos] == '"'). Returns the index of the matching
// closing quote, or -1 if the string is unterminated or malformed.
//
// Honours backslash escapes — `\"` does NOT terminate the string.  The
// escape sequence itself is preserved in the substring; callers should
// pass the raw substring to `decodeJsonEscapes` before using it.
func scanJsonString(json: in String, quotePos: in Int): Int {
  if quotePos < 0 or quotePos >= json.length { return -1 }
  if json[quotePos] != '"' { return -1 }
  var i = quotePos + 1
  while i < json.length {
    val c = json[i]
    if c == '"' { return i }
    if c == '\\' {
      if i + 1 >= json.length { return -1 }
      i = i + 2  // skip backslash + escaped char (or \uXXXX prefix)
    } else {
      i = i + 1
    }
  }
  -1
}

// Check whether `audience` appears in the `aud` claim of `json`, where
// `aud` may be either a string (RFC 7519 §4.1.3 string form) or a JSON
// array of strings.  Returns true when the audience matches either form;
// false when the claim is absent or no element matches.  Used by
// `validatePayload` so JWT issuers that emit array-form audiences
// (Keycloak, Auth0, some AWS services) validate correctly (#1089).
//
// Both forms apply `decodeJsonEscapes` to the raw string contents before
// comparison so escape sequences in the issuer's aud match callers'
// unescaped expected audiences (#1079).
//
// Last-wins semantics (#1162): per RFC 8259 §4 duplicate-key behaviour
// is implementation-defined, but `getStringClaimFromJson` already picks
// the last occurrence via `lastIndexOf` for non-array claims.  Mirror
// that here: when `"aud":"..."` and `"aud":[...]` both appear, the one
// at the later byte offset wins.  Without this, a leading string-form
// `aud` would mask a later array-form re-statement (or vice versa).
func audienceMatches(json: in String, audience: in String): Bool {
  if audience.length == 0 { return true }
  val pfxStr = "\"aud\":\""
  val pfxStrPos = json.lastIndexOf(pfxStr)
  val pfxArr = "\"aud\":["
  val pfxArrPos = json.lastIndexOf(pfxArr)
  // Only the later occurrence is authoritative — earlier `aud` declarations
  // are shadowed (#1162).  When both forms appear, the one with the larger
  // byte offset wins; the other is not consulted.
  val useArr = pfxArrPos > pfxStrPos
  if useArr {
    var i = pfxArrPos + pfxArr.length
    while i < json.length and json[i] != ']' {
      if json[i] == '"' {
        val openQuote = i
        val closeQuote = scanJsonString(json, openQuote)
        if closeQuote < 0 { return false }
        val raw = substring(json, openQuote + 1, closeQuote - openQuote - 1)
        if decodeJsonEscapes(raw) == audience { return true }
        i = closeQuote + 1
      } else {
        i = i + 1
      }
    }
    return false
  }
  if pfxStrPos < 0 { return false }
  val openQuote = pfxStrPos + pfxStr.length - 1
  val closeQuote = scanJsonString(json, openQuote)
  if closeQuote <= openQuote { return false }
  val raw = substring(json, openQuote + 1, closeQuote - openQuote - 1)
  decodeJsonEscapes(raw) == audience
}

// Extract a string-valued claim from a JSON object string.
// Scans for `"key":"VALUE"` using lastIndexOf for last-wins duplicate-key
// semantics (RFC 8259 §4; matches most JWT library parsers).
//
// Honours backslash-escape sequences so `\"` inside the value does not
// terminate scanning prematurely (#1079).  The result is passed through
// `decodeJsonEscapes` so callers see the actual character data, not the
// raw backslash-encoded form (i.e. `"O\"Brien"` returns `O"Brien`,
// `"line1\nline2"` returns the two lines joined by a literal LF, and
// `"é"` returns U+00E9).
//
// Returns "" when the key is absent or the JSON is malformed.
func getStringClaimFromJson(json: in String, key: in String): String {
  val pfx = "\"" + key + "\":\""
  val pfxPos = json.lastIndexOf(pfx)
  if pfxPos < 0 { return "" }
  // Opening quote of the value (the second `"` in `"key":"`).
  val openQuote = pfxPos + pfx.length - 1
  val closeQuote = scanJsonString(json, openQuote)
  if closeQuote < 0 { return "" }
  val count = closeQuote - openQuote - 1
  if count == 0 { return "" }
  decodeJsonEscapes(substring(json, openQuote + 1, count))
}

// Extract a string claim from a UTF-8-encoded payload byte slice.
// Returns "" when decoding fails or the claim is absent.
func getStringClaim(payloadBytes: in slice[Byte], key: in String): String {
  match tryDecodeUtf8(payloadBytes) {
    case None -> ""
    case Some(json) -> getStringClaimFromJson(json, key)
  }
}

// ─── parseLong (#1088) ────────────────────────────────────────────────────────

// Parse a non-negative decimal integer string to Long, with JWT-specific
// semantics: rejects empty input and any non-digit character, and treats
// any input longer than 18 digits as overflow.  Designed for JWT
// exp/nbf claims and intentionally narrower than `Std.Parse.parseLong`;
// not part of the kernel public API (package-private, #1159).
//
// Returns:
//   Ok(value)            — successfully parsed
//   Err("parse_error")   — empty input or non-digit character
//   Err("overflow")      — input longer than 18 digits (Long.MaxValue has 19
//                          digits; 18-digit cap prevents unchecked overflow
//                          from turning large-but-present exp/nbf claims into
//                          negative values that silently bypass expiry — #1078).
//
// 18 digits is conservative (Long.MaxValue is 9223372036854775807, 19 digits)
// but avoids per-digit overflow checks in the hot loop and keeps the spec
// simple.
func parseLong(s: in String): Result[Long, String] {
  if s.length == 0  { return Err("parse_error") }
  if s.length > 18  { return Err("overflow") }
  // Variable name avoids `result` because that's a reserved keyword
  // in `ensures:` clauses; the parser/elaborator treats every
  // occurrence as the special `EResult` expression even when the
  // enclosing function has no `ensures:` and will hit
  // "E11 codegen: EResult outside contract context" at lower time.
  var acc: Long = 0i64
  var i = 0
  while i < s.length {
    if not isDigit(s[i]) { return Err("parse_error") }
    val d = toInt(s[i]) - toInt('0')
    acc = acc * 10i64 + intToLong(d)
    i = i + 1
  }
  Ok(acc)
}

// Extract a numeric (integer) claim from a JSON object string.
// Scans for `"key":NUMBER` using lastIndexOf for last-wins duplicate-key
// semantics.
//
// Returns Result[Option[Long], String]:
//   Ok(None)         — key absent (caller should skip the claim check)
//   Ok(Some(v))      — key present and parsed successfully
//   Err("overflow")  — key present but value overflows Long (caller MUST
//                      reject the token — skipping the check on a present-
//                      but-unparseable claim would silently bypass exp/nbf
//                      enforcement, #1078)
//   Err("parse_error") — key present but value malformed (non-digit, empty)
func getLongClaimFromJson(json: in String, key: in String): Result[Option[Long], String] {
  val pfx = "\"" + key + "\":"
  val pfxPos = json.lastIndexOf(pfx)
  if pfxPos < 0 { return Ok(None) }
  var vs = pfxPos + pfx.length
  // Skip any whitespace between ':' and the number.
  while vs < json.length and json[vs] == ' ' {
    vs = vs + 1
  }
  // Key is present from here on; any parse failure is Err, not Ok(None).
  if vs >= json.length { return Err("parse_error") }
  if not isDigit(json[vs]) { return Err("parse_error") }
  var ve = vs
  while ve < json.length and isDigit(json[ve]) {
    ve = ve + 1
  }
  val count = ve - vs
  if count == 0 { return Err("parse_error") }
  val numStr = substring(json, vs, count)
  match parseLong(numStr) {
    case Ok(v)  -> Ok(Some(value = v))
    case Err(e) -> Err(e)
  }
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
// claims.  Returns:
//   Ok(())                       — payload well-formed and all checks passed
//   Err("MALFORMED_PAYLOAD")     — base64url or UTF-8 decode failed
//   Err("ISSUER_MISMATCH")       — iss claim does not match expected issuer
//   Err("AUDIENCE_MISMATCH")     — aud claim does not contain expected audience
//   Err("EXP_OVERFLOW")          — exp present but malformed/overflowed
//   Err("EXPIRED")               — exp in the past (beyond clockSkewSeconds)
//   Err("NBF_OVERFLOW")          — nbf present but malformed/overflowed
//   Err("NOT_YET_VALID")         — nbf in the future (beyond clockSkewSeconds)
//
// `clockSkewSeconds` (#1081) widens the validity window symmetrically:
//   token valid if  exp + clockSkewSeconds >= nowSec
//   token valid if  nbf - clockSkewSeconds <= nowSec
// The default at the public API layer is 60 seconds (industry standard;
// Auth0, AWS Cognito, etc.).
func validatePayload(
  payloadSeg:       in String,
  issuer:           in String,
  audience:         in String,
  clockSkewSeconds: in Int
): Result[Unit, String] {
  match fromBase64Url(payloadSeg) {
    case None -> Err("MALFORMED_PAYLOAD")
    case Some(payloadBytes) -> {
      match tryDecodeUtf8(payloadBytes) {
        case None -> Err("MALFORMED_PAYLOAD")
        case Some(payloadJson) -> {
          // Capture the current time once for consistent exp/nbf evaluation.
          val nowSec: Long = nowEpochMillis() / 1000i64
          val skewLong: Long = toLong(clockSkewSeconds)
          // Validate iss claim when the caller supplied a non-empty issuer.
          if issuer.length > 0 {
            val iss = getStringClaimFromJson(payloadJson, "iss")
            if iss != issuer { return Err("ISSUER_MISMATCH") }
          }
          // Validate aud claim when the caller supplied a non-empty audience.
          // RFC 7519 §4.1.3 permits both string and array forms; see
          // audienceMatches (#1089).
          if audience.length > 0 {
            if not audienceMatches(payloadJson, audience) {
              return Err("AUDIENCE_MISMATCH")
            }
          }
          // Validate exp with clock-skew leeway (#1081).  A present-but-
          // malformed exp is fatal (#1078).
          match getLongClaimFromJson(payloadJson, "exp") {
            case Err(_) -> { return Err("EXP_OVERFLOW") }
            case Ok(opt) -> {
              match opt {
                case None    -> ()
                case Some(exp) -> {
                  // Reject when nowSec is past exp + skew.
                  if nowSec > exp + skewLong { return Err("EXPIRED") }
                }
              }
            }
          }
          // Validate nbf with clock-skew leeway (#1081).
          match getLongClaimFromJson(payloadJson, "nbf") {
            case Err(_) -> { return Err("NBF_OVERFLOW") }
            case Ok(opt) -> {
              match opt {
                case None    -> ()
                case Some(nbf) -> {
                  // Reject when nowSec is earlier than nbf - skew.
                  if nowSec < nbf - skewLong { return Err("NOT_YET_VALID") }
                }
              }
            }
          }
          Ok(())
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
/// and other public-key algorithms return Err("ALG_UNSUPPORTED"); full
/// public-key support is tracked in #443.
///
/// Returns Result[Unit, String]:
///   Ok(())                   — token well-formed, signature verified, all claims passed
///   Err("MALFORMED_TOKEN")   — wrong number of dot-separated segments
///   Err("MALFORMED_HEADER")  — header base64url/UTF-8/JSON parse failed
///   Err("ALG_UNSUPPORTED")   — token alg is not HS256 (kernel limitation)
///   Err("ALG_REJECTED")      — alg not in allowedAlgorithms
///   Err("BAD_SIGNATURE")     — HMAC verification failed
///   Err("MALFORMED_PAYLOAD") — payload base64url/UTF-8/JSON parse failed
///   Err("ISSUER_MISMATCH")   — iss claim mismatched
///   Err("AUDIENCE_MISMATCH") — aud claim mismatched
///   Err("EXP_OVERFLOW")      — exp present but malformed
///   Err("EXPIRED")           — exp in the past
///   Err("NBF_OVERFLOW")      — nbf present but malformed
///   Err("NOT_YET_VALID")     — nbf in the future
///
/// `clockSkewSeconds` adds symmetric leeway to exp and nbf checks (#1081).
///
// Named verifyJwtImpl (not verifyJwt) to avoid a same-name collision with the
// Auth.verifyJwt wrapper in auth.l when compiled in project mode: the alias
// rewriter turns `AuthKernelNet.verifyJwt(...)` → `verifyJwt(...)`, which the
// codegen resolves to the current package's function (Auth.verifyJwt) rather
// than this kernel function, causing infinite recursion.  Using a distinct
// name ensures the call resolves to this implementation regardless of
// compilation mode.  Tracked in #1127 (root alias-rewriter bug, #1094).
@stable(since="0.1")
pub func verifyJwtImpl(
  token:             in String,
  secret:            in String,
  issuer:            in String,
  audience:          in String,
  allowedAlgorithms: in String,
  clockSkewSeconds:  in Int
): Result[Unit, String]
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
  requires: clockSkewSeconds >= 0
{
  // Split into header.payload.signature — must be exactly three parts.
  val parts = split(token, ".")
  if parts.length != 3 { return Err("MALFORMED_TOKEN") }

  // Extract alg from header.
  val alg = jwtAlgFromHeader(parts[0])
  if alg.length == 0 { return Err("MALFORMED_HEADER") }

  // Reject before signature verification when alg is not in the caller's
  // allow-list (#1090) — surfaces a distinct error from BAD_SIGNATURE so
  // callers can distinguish algorithm rejection from cryptographic failure.
  if not algListContains(allowedAlgorithms, alg) { return Err("ALG_REJECTED") }

  // This kernel only implements HS256.  When the caller-allowed alg is
  // something else (e.g. RS256), return ALG_UNSUPPORTED to make the
  // limitation explicit rather than masking it as BAD_SIGNATURE (#1090).
  if alg != "HS256" { return Err("ALG_UNSUPPORTED") }

  // Verify HMAC-SHA256 signature over header.payload.
  val signingInput = parts[0] + "." + parts[1]
  val signingInputBytes = encodeUtf8(signingInput)
  val secretBytes = encodeUtf8(secret)
  val expectedSig = hmacSha256(secretBytes, signingInputBytes)
  match fromBase64Url(parts[2]) {
    case None -> return Err("BAD_SIGNATURE")
    case Some(providedSig) -> {
      if not fixedTimeEqualBytes(expectedSig, providedSig) {
        return Err("BAD_SIGNATURE")
      }
    }
  }

  // Validate payload claims (iss, aud, exp, nbf) with clock-skew leeway.
  return validatePayload(parts[1], issuer, audience, clockSkewSeconds)
}

// ─── Claim extraction ─────────────────────────────────────────────────────────

/// Try to extract a named string claim from a JWT payload segment.
/// Sets `value` to the claim string and returns true on success.
/// Sets `value` to `""` and returns false for absent claims or malformed tokens.
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
  if parts.length < 2 {
    value = ""
    return false
  }
  match fromBase64Url(parts[1]) {
    case None -> {
      value = ""
      false
    }
    case Some(payloadBytes) -> {
      val claim = getStringClaim(payloadBytes, claimKey)
      if claim.length == 0 {
        value = ""
        return false
      }
      value = claim
      true
    }
  }
}

/// Extract a named claim from a JWT payload without re-verifying the signature.
/// Call only on tokens already accepted by verifyJwt.
/// Returns None if the claim is absent or the token is malformed.
// See verifyJwtImpl for the naming rationale — same collision avoidance.
@stable(since="0.1")
pub func extractClaimImpl(token: in String, claimKey: in String): Option[String]
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
// See verifyJwtImpl for the naming rationale — same collision avoidance.
@stable(since="0.1")
pub func verifyApiKeyImpl(provided: in String, expected: in String): Bool
  requires: expected.length > 0
{
  val a = encodeUtf8(provided)
  val b = encodeUtf8(expected)
  fixedTimeEqualBytes(a, b)
}
