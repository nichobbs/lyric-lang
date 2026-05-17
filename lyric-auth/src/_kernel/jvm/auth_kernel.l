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
  /// INTERFACE-ONLY: the signature reserves the algorithm-pinning
  /// argument; the JVM host shim still needs to configure JJWT's
  /// parser with the matching `SignatureAlgorithm` whitelist so the
  /// underlying validator rejects `alg=none` and mismatched algorithms.
  /// See lyric-lang issue #315 follow-up.
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
