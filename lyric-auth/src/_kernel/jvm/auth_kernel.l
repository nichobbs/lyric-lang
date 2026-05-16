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
  pub func verifyJwt(
    token:    String,
    secret:   String,
    issuer:   String,
    audience: String
  ): Bool
    requires: secret.length > 0

  pub func extractClaim(token: String, claimKey: String): Option[String]
    requires: claimKey.length > 0
}

@axiom("java.security.MessageDigest for constant-time comparison")
extern package java.security {
  pub func verifyApiKey(provided: String, expected: String): Bool
    requires: expected.length > 0
}
