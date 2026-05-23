// Auth.Kernel.Net — .NET authentication extern boundary.
//
// Bridges Auth's verification functions to BCL crypto primitives via the
// `Lyric.Auth.AuthHost` host shim (bootstrap/src/Lyric.Auth.Host/).
//
// The `extern package` form used in early drafts of this file was metadata-only
// — the emitter emits no IL for those declarations, making them uncallable.
// This file uses `@externTarget("Lyric.Auth.AuthHost.<method>")` instead,
// which the emitter resolves to a real static-method call at codegen time.
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

// ─── JWT verification ─────────────────────────────────────────────────────────

/// Validate a Bearer JWT against an explicit allow-list of algorithms.
///
/// `allowedAlgorithms` is a comma-separated string of JWT `alg` values
/// (e.g. "HS256" or "HS256,RS256") that the caller is prepared to honour.
/// The Lyric-level contract `requires: allowedAlgorithms.length > 0` enforces
/// the explicit allow-list at the boundary.
///
/// Algorithm enforcement is applied at the Lyric layer (in Auth.verifyJwt)
/// before this extern is called, so alg=none and algorithm-confusion attacks
/// are rejected before reaching the BCL validator.  The host shim wires
/// `allowedAlgorithms` into `ValidAlgorithms` for defence-in-depth (#443).
///
/// Returns true iff the token is well-formed, its signature verifies against
/// `secret`, and — when non-empty — the `issuer` and `audience` claims match.
@axiom("Lyric.Auth.AuthHost.verifyJwt — BCL HMAC-SHA256 JWT validation")
@externTarget("Lyric.Auth.AuthHost.verifyJwt")
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
  = ()

// ─── Claim extraction ─────────────────────────────────────────────────────────

/// Try to extract a named claim from a JWT payload segment.
/// Sets `value` to the claim string and returns true on success.
/// Returns false and leaves `value` unchanged for absent claims or malformed tokens.
/// Call only on tokens already accepted by verifyJwt.
@axiom("Lyric.Auth.AuthHost.tryExtractClaim — JWT payload claim extraction")
@externTarget("Lyric.Auth.AuthHost.tryExtractClaim")
@stable(since="0.1")
pub func tryExtractClaim(
  token:    in  String,
  claimKey: in  String,
  value:    out String
): Bool
  requires: claimKey.length > 0
  = ()

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

// ─── API key ──────────────────────────────────────────────────────────────────

/// Constant-time comparison of `provided` against `expected`.
/// Returns true iff the two strings are byte-for-byte identical.
/// Constant-time prevents timing-oracle attacks on API keys.
@axiom("Lyric.Auth.AuthHost.verifyApiKey — CryptographicOperations.FixedTimeEquals")
@externTarget("Lyric.Auth.AuthHost.verifyApiKey")
@stable(since="0.1")
pub func verifyApiKey(provided: in String, expected: in String): Bool
  requires: expected.length > 0
  = ()
