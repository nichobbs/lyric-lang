/// Auth.Kernel.Net — .NET authentication extern boundary.
///
/// Bridges Auth's verification functions to System.IdentityModel.Tokens.Jwt
/// (JWT) and BCL string-comparison primitives (API key).
///
/// Only active when compiled with feature = "dotnet".
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Auth.Kernel.Net

import Std.Core

// ─── JWT ─────────────────────────────────────────────────────────────────────

@axiom("System.IdentityModel.Tokens.Jwt for token validation")
extern package System.IdentityModel.Tokens.Jwt {
  /// Validate a Bearer JWT (HMAC-SHA256 or RS256).
  /// Returns true iff the token is well-formed, the signature verifies against
  /// `secret`, and — when non-empty — the `issuer` and `audience` claims match.
  pub func verifyJwt(
    token:    String,
    secret:   String,
    issuer:   String,
    audience: String
  ): Bool
    requires: secret.length > 0

  /// Extract a named claim from a JWT without re-verifying the signature.
  /// Call only on tokens already accepted by verifyJwt.
  /// Returns None if the claim is absent or the token is malformed.
  pub func extractClaim(token: String, claimKey: String): Option[String]
    requires: claimKey.length > 0
}

// ─── API key ──────────────────────────────────────────────────────────────────

@axiom("System cryptographic comparison primitives")
extern package System.Security.Cryptography {
  /// Constant-time comparison of `provided` against `expected`.
  /// Returns true iff the two strings are byte-for-byte identical.
  /// Constant-time prevents timing-oracle attacks on API keys.
  pub func verifyApiKey(provided: String, expected: String): Bool
    requires: expected.length > 0
}
