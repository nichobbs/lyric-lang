// AwsSecrets.Kernel.Net (local) — no-op secrets backend for local development.
//
// In local mode (feature = "local"):
//
//   initFromAnnotations() — scans config-block annotations exactly as the aws
//     kernel does, but skips all AWS fetches.  Fields with env var overrides
//     are left as-is.  Fields without overrides are left unset; they will
//     cause a missing-config-value error when first accessed, which surfaces
//     the missing local override clearly during development.
//
//   fetchSecret / fetchParameter — always return SecretsError.NotFound so
//     callers can distinguish "no local override" from "AWS fetch failed".
//
// Local development workflow:
//   Set LYRIC_CONFIG_<PACKAGE>_<FIELD> env vars for any @secretsManager /
//   @parameterStore annotated fields you need during local development.
//   AwsSecrets.init() will skip the AWS fetch for fields that have env vars
//   set, so no AWS credentials are required.
//
//   For fields without local env vars, init() succeeds (returns Ok) but the
//   config field will be missing when first read.  This is intentional: it
//   forces local env vars to be set explicitly rather than silently using
//   empty strings.
//
// Enabled only when the "local" feature flag is active.

@cfg(feature = "local")
package AwsSecrets.Kernel.Net

import AwsSecrets

@axiom("No-op local backend — uses env var overrides only; no AWS SDK calls")
extern package AwsSecrets.LocalBackend {
  /// Scan annotations; skip AWS fetches; respect env var overrides.
  /// Returns Ok(()) even if some annotated fields lack local env vars.
  pub func initFromAnnotations(ttlSeconds: Int): Result[Unit, AwsSecrets.SecretsError]

  /// Always returns SecretsError.NotFound — no AWS SDK in local mode.
  /// Set the corresponding env var instead.
  pub func fetchSecret(
    name:       String,
    key:        Option[String],
    ttlSeconds: Int
  ): Result[String, AwsSecrets.SecretsError]
    requires: name.length > 0

  /// Always returns SecretsError.NotFound — no AWS SDK in local mode.
  pub func fetchParameter(
    path:       String,
    decrypt:    Bool,
    ttlSeconds: Int
  ): Result[String, AwsSecrets.SecretsError]
    requires: path.length > 0
}
