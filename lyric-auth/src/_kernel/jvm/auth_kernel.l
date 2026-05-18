/// Auth.Kernel.Jvm — JVM authentication extern boundary.
///
/// Bridges Auth's verification functions to io.jsonwebtoken (JJWT) for
/// JWT handling and MessageDigest for constant-time key comparison.
///
/// Only active when compiled with feature = "jvm" (Phase 6).
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "jvm")
package Auth.Kernel.Jvm

import Std.Core

@axiom("io.jsonwebtoken:jjwt-api for JWT verification")
extern package io.jsonwebtoken {
  /// Validate a Bearer JWT against an explicit allow-list of algorithms.
  /// `allowedAlgorithms` is a comma-separated string of JWT `alg` values
  /// (e.g. "HS256" or "HS256,RS256") that the caller is prepared to
  /// honour.  The Lyric-level contract
  /// `requires: allowedAlgorithms.length > 0` enforces the explicit
  /// allow-list at the boundary.
  ///
  /// Algorithm enforcement is applied at the Lyric layer (in Auth.verifyJwt)
  /// before this extern is called, so alg=none and algorithm-confusion attacks
  /// are rejected before reaching the JVM validator.  The host shim should
  /// also configure JJWT's parser with the matching `SignatureAlgorithm`
  /// whitelist for defence-in-depth (see lyric-lang #443 and #315 follow-up).
  pub func verifyJwt(
    token:             String,
    secret:            String,
    issuer:            String,
    audience:          String,
    allowedAlgorithms: String
  ): Bool
    requires: secret.length > 0
    requires: allowedAlgorithms.length > 0

  pub func extractClaim(token: String, claimKey: String): Option[String]
    requires: claimKey.length > 0
}

@axiom("java.security.MessageDigest for constant-time comparison")
extern package java.security {
  pub func verifyApiKey(provided: String, expected: String): Bool
    requires: expected.length > 0
}
