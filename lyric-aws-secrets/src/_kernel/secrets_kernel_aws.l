// AwsSecrets.Kernel.Net (aws) — AWS SDK extern boundary for secrets and parameters.
//
// Bridges AwsSecrets to the AWS .NET SDK clients:
//   Amazon.SecretsManager       — AWSSDK.SecretsManager 3.7.x
//   Amazon.SimpleSystemsManagement — AWSSDK.SimpleSystemsManagement 3.7.x
//
// initFromAnnotations():
//   1. Scan the compiled DLL's config block metadata for fields annotated
//      with @secretsManager or @parameterStore.
//   2. For each annotated field, check whether the corresponding env var
//      (LYRIC_CONFIG_<PACKAGE>_<FIELD>) is already set; if so, skip the
//      AWS fetch (env var takes precedence for local dev overrides).
//   3. Fetch the secret / parameter value via the SDK.
//   4. Store the value in the process-level config cache under the env-var key.
//   5. Return Ok(()) if all fetches succeed; Err(SecretsError) on the first failure.
//
// fetchSecret(name, key, ttlSeconds):
//   Calls GetSecretValueAsync.  If key is Some, parses the value as JSON
//   and extracts the named field.  Caches under (name, key) for ttlSeconds.
//
// fetchParameter(path, decrypt, ttlSeconds):
//   Calls GetParameterAsync with WithDecryption = decrypt.
//   Caches under path for ttlSeconds.
//
// Cache implementation:
//   In-process Dictionary<string, (string value, DateTime expiresAt)>.
//   Thread-safe via lock (Lambda single-threaded by default; lock is a
//   no-cost fast path in the uncontended case).
//
// IAM requirements:
//   The Lambda execution role must have:
//     secretsmanager:GetSecretValue on the target secrets
//     ssm:GetParameter on the target parameters
//     kms:Decrypt on the KMS keys protecting SecureString parameters
//
// Enabled only when the "aws" feature flag is active.
// See docs/35-lambda-library.md §6, docs/14-native-stdlib-plan.md.

@cfg(feature = "aws")
package AwsSecrets.Kernel.Net

import AwsSecrets

@axiom("AWSSDK.SecretsManager + AWSSDK.SimpleSystemsManagement 3.7.x")
extern package Amazon.SecretsManager {
  /// Scan config-block annotations and populate the config cache.
  /// Returns Ok(()) on full success or Err(message) on the first failure.
  pub func initFromAnnotations(ttlSeconds: Int): Result[Unit, AwsSecrets.SecretsError]

  /// Fetch a Secrets Manager secret value, optionally extracting a JSON key.
  /// key = None: return the raw secret string.
  /// key = Some(k): parse as JSON object and return field k.
  pub func fetchSecret(
    name:       String,
    key:        Option[String],
    ttlSeconds: Int
  ): Result[String, AwsSecrets.SecretsError]
    requires: name.length > 0
}

@axiom("AWSSDK.SimpleSystemsManagement 3.7.x")
extern package Amazon.SimpleSystemsManagement {
  /// Fetch a Parameter Store parameter.
  /// decrypt = true: call GetParameter with WithDecryption=true (SecureString).
  /// decrypt = false: return the raw ciphertext for String parameters.
  pub func fetchParameter(
    path:       String,
    decrypt:    Bool,
    ttlSeconds: Int
  ): Result[String, AwsSecrets.SecretsError]
    requires: path.length > 0
}
