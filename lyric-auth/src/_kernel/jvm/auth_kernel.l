// Auth.Kernel.Jvm — JVM authentication extern boundary.
//
// Bridges Auth's verification functions to io.jsonwebtoken (JJWT) for
// JWT handling and MessageDigest for constant-time key comparison.
//
// Only active when compiled with feature = "jvm" (Phase 6).
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.
//
// Algorithm enforcement is applied at the Lyric layer in Auth.verifyJwt
// before this extern is called, so alg=none and algorithm-confusion attacks
// are rejected before reaching the JVM validator.  The host shim should
// also configure JJWT's parser with the matching `SignatureAlgorithm`
// whitelist for defence-in-depth (see lyric-lang #443 and #315 follow-up).
//
// The Bool-returning extern is wrapped by `verifyJwtImpl` so the public
// surface matches the .NET kernel — both expose `Result[Unit, String]`
// where the string is a stable error code (#1090).  The JVM path cannot
// distinguish specific failure modes today (JJWT throws a single
// `JwtException` for any verification failure), so it returns either
// Ok(()) or Err("VERIFICATION_FAILED").  Surface-richer JVM errors are
// tracked in #443.

@cfg(feature = "jvm")
package Auth.Kernel.Jvm

import Std.Core

@axiom("io.jsonwebtoken:jjwt-api for JWT verification")
extern package io.jsonwebtoken {
  /// Validate a Bearer JWT against an explicit allow-list of algorithms.
  /// `allowedAlgorithms` is a comma-separated string of JWT `alg` values
  /// (e.g. "HS256" or "HS256,RS256") that the caller is prepared to honour.
  ///
  /// `clockSkewSeconds` widens both the `exp` and `nbf` validation windows
  /// symmetrically.  Default at the public API is 60 seconds (industry
  /// standard); the host shim must forward this to JJWT's `allowedClockSkew`.
  pub func verifyJwt(
    token:             String,
    secret:            String,
    issuer:            String,
    audience:          String,
    allowedAlgorithms: String,
    clockSkewSeconds:  Int
  ): Bool
    requires: secret.length > 0
    requires: allowedAlgorithms.length > 0
    requires: clockSkewSeconds >= 0

  pub func extractClaim(token: String, claimKey: String): Option[String]
    requires: claimKey.length > 0
}

@axiom("java.security.MessageDigest for constant-time comparison")
extern package java.security {
  pub func verifyApiKey(provided: String, expected: String): Bool
    requires: expected.length > 0
}

/// Wrap the Bool-returning extern in a Result so the JVM kernel exposes the
/// same public-API contract as Auth.Kernel.Net's `verifyJwtImpl`.  See file
/// header for the algorithm-pinning split between the Lyric layer and the
/// host validator.
///
/// Returns:
///   Ok(())                       — token verified successfully
///   Err("VERIFICATION_FAILED")   — any failure (signature, claims, exp/nbf,
///                                  issuer, audience, alg).  The JVM path
///                                  cannot distinguish failure modes today;
///                                  surface-rich errors tracked in #443.
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
  if verifyJwt(token, secret, issuer, audience, allowedAlgorithms, clockSkewSeconds) {
    Ok(())
  } else {
    Err("VERIFICATION_FAILED")
  }
}
