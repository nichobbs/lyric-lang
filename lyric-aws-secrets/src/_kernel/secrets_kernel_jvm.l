/// AwsSecrets.Kernel.Net (jvm) — AWS SDK for Java v2 extern boundary.
///
/// Bridges AwsSecrets to the AWS SDK for Java v2 clients:
///   software.amazon.awssdk:secretsmanager  — Secrets Manager
///   software.amazon.awssdk:ssm             — Systems Manager Parameter Store
///
/// initFromAnnotations():
///   Scans the compiled JVM class metadata for @secretsManager and
///   @parameterStore annotations on config block fields (stored as JVM
///   class-file annotations by the Lyric JVM emitter).
///   For each annotated field, checks whether the corresponding env var
///   (LYRIC_CONFIG_<PACKAGE>_<FIELD>) is already set; if so, skips the
///   AWS fetch.  Otherwise fetches and stores the value in the config cache.
///
/// fetchSecret(name, key, ttlSeconds):
///   Calls SecretsManagerClient.getSecretValue().  If key is Some, parses
///   the SecretString as JSON and extracts the named field via Jackson.
///   Caches under (name, key) for ttlSeconds using a ConcurrentHashMap with
///   per-entry expiry timestamps.
///
/// fetchParameter(path, decrypt, ttlSeconds):
///   Calls SsmClient.getParameter() with withDecryption = decrypt.
///   Caches under path for ttlSeconds.
///
/// Region: resolved from the AWS_DEFAULT_REGION / AWS_REGION env vars or
/// from the EC2 instance metadata service, exactly as the SDK defaults.
///
/// IAM requirements:
///   The Lambda execution role must have:
///     secretsmanager:GetSecretValue on target secrets
///     ssm:GetParameter on target parameters
///     kms:Decrypt on KMS keys protecting SecureString parameters
///
/// Maven dependencies (resolved when target = "jvm"):
///   software.amazon.awssdk:secretsmanager:2.25.70
///   software.amazon.awssdk:ssm:2.25.70
///
/// Enabled only when the "jvm" feature flag is active.
/// See docs/35-lambda-library.md §12.3.

@cfg(feature = "jvm")
package AwsSecrets.Kernel.Net

import AwsSecrets

@axiom("software.amazon.awssdk:secretsmanager + ssm 2.25.70 (AWS SDK for Java v2)")
extern package software.amazon.awssdk.secrets {
  pub func initFromAnnotations(ttlSeconds: Int): Result[Unit, AwsSecrets.SecretsError]

  pub func fetchSecret(
    name:       String,
    key:        Option[String],
    ttlSeconds: Int
  ): Result[String, AwsSecrets.SecretsError]
    requires: name.length > 0

  pub func fetchParameter(
    path:       String,
    decrypt:    Bool,
    ttlSeconds: Int
  ): Result[String, AwsSecrets.SecretsError]
    requires: path.length > 0
}
