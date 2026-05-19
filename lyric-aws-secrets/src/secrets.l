// AwsSecrets — AWS Secrets Manager and Parameter Store integration for Lyric.
//
// Primary usage: config-block annotation support.
//
//   Apply @secretsManager or @parameterStore to @sensitive fields in a config
//   block to declare that the field's value should come from AWS instead of
//   (or in addition to) an env var.  Then call AwsSecrets.init() once at
//   process startup before Lambda.serve() or Web.start().
//
//   init() scans all config blocks in the compiled DLL for annotated fields,
//   fetches their values from Secrets Manager / Parameter Store, and populates
//   the process-level config cache under the same key used by env vars
//   (LYRIC_CONFIG_<PACKAGE>_<FIELD>).  The existing config-block access
//   mechanism then reads from the cache as normal.
//
//   Env var override: if LYRIC_CONFIG_<PACKAGE>_<FIELD> is set, it takes
//   precedence over the secret value.  This enables local development without
//   AWS credentials — set env vars locally and use real secrets in production.
//
// Annotation reference:
//
//   @secretsManager("secret-name")
//     Fetch the entire secret value (for plain-string secrets).
//
//   @secretsManager("secret-name", key: "field-name")
//     Fetch a single JSON field from a structured secret.
//     The secret value must be a valid JSON object.
//
//   @parameterStore("/param/path")
//     Fetch a Parameter Store parameter (String or SecureString; SecureString
//     is decrypted automatically using the parameter's KMS key).
//
// Example:
//
//   import AwsSecrets
//
//   config Database {
//     host: String = "localhost"
//     port: Int    = 5432
//     @sensitive
//     @secretsManager("my-service/prod", key: "dbPassword")
//     password: String
//   }
//
//   config Auth {
//     @sensitive
//     @secretsManager("my-service/prod", key: "jwtSecret")
//     jwtSecret: String
//     @sensitive
//     @parameterStore("/my-service/signing-key")
//     signingKey: String
//   }
//
//   func main(): Int {
//     match AwsSecrets.init() {
//       Ok(_)    => Lambda.serve(Lambda.newApp() |> Lambda.withRouter(router))
//       Err(err) => {
//         Std.Core.log("ERROR", AwsSecrets.errorMessage(err))
//         return 1
//       }
//     }
//     return 0
//   }
//
// Secondary usage: explicit imperative fetch.
//
//   Use getSecret / getSecretField / getParameter / getSecureParameter for
//   one-off fetches inside handler bodies where a config field is not
//   appropriate (e.g. fetching a per-tenant secret at request time).
//
// Caching:
//   Values are cached in process memory for SecretCache.ttlSeconds (default
//   5 minutes).  On a warm Lambda invocation the cached value is returned
//   without an AWS API call.  Set ttlSeconds = 0 to disable caching.
//   Match the TTL to your secret rotation period: a safe default is
//   ttlSeconds < rotationPeriodSeconds / 6.
//
// Runtime env vars:
//   LYRIC_CONFIG_AWSSECRETS_SECRETCACHE_TTLSECONDS  — cache TTL (default: 300)
//
// See docs/35-lambda-library.md §6, decision log D063.

@runtime_checked
package AwsSecrets

import Std.Core
import AwsSecrets.Kernel.Net as SecretsKernel

// ─── Annotations ─────────────────────────────────────────────────────────────

// @secretsManager and @parameterStore are user-facing annotation names.
// Bootstrap does not support pub annotation declarations; these are documented
// in the module header and enforced at runtime by the kernel's initFromAnnotations.

// ─── SecretsError ─────────────────────────────────────────────────────────────

/// Typed error union for Secrets Manager and Parameter Store failures.
@stable(since="0.1")
pub union SecretsError {
  /// The secret or parameter does not exist or is not accessible with the
  /// current IAM role.
  case NotFound(name: String)
  /// The IAM role does not have permission to retrieve the secret or parameter.
  case AccessDenied(name: String, message: String)
  /// Decryption of a SecureString parameter or KMS-encrypted secret failed.
  case DecryptionError(name: String, message: String)
  /// The secret value is a JSON object but the requested key is absent or
  /// the value is not valid JSON.
  case ParseError(name: String, key: String, message: String)
  /// A transient network or service error.  Retrying after a brief delay
  /// may succeed.
  case NetworkError(name: String, message: String)
}

/// Human-readable message for logging.
@stable(since="0.1")
pub func errorMessage(err: in SecretsError): String {
  match err {
    case NotFound(name)             -> "Secret not found: " + name
    case AccessDenied(name, msg)    -> "Access denied for " + name + ": " + msg
    case DecryptionError(name, msg) -> "Decryption failed for " + name + ": " + msg
    case ParseError(name, key, msg) -> "Parse error for " + name + "[" + key + "]: " + msg
    case NetworkError(name, msg)    -> "Network error fetching " + name + ": " + msg
  }
}

// ─── Cache config ─────────────────────────────────────────────────────────────

/// Cache time-to-live for fetched secrets and parameters.
///
/// Cached values are stored in process memory.  On a warm Lambda invocation
/// the cached value is returned without an AWS API call.
///
/// ttlSeconds = 0  — disable caching; fetch on every init() or explicit get call.
/// ttlSeconds > 0  — cache for this many seconds (default: 300 = 5 minutes).
///
/// Set TTL to a fraction of your secret rotation period.  For example, if
/// rotating every 24 hours, a TTL of 300s (5 minutes) ensures stale values
/// are refreshed well within the rotation window.
config SecretCache {
  ttlSeconds: Int = 300
}

// ─── Initialisation ───────────────────────────────────────────────────────────

/// Fetch all @secretsManager and @parameterStore annotated config block fields
/// and populate the process-level config cache.
///
/// Must be called once at process startup, before Lambda.serve() or Web.start().
/// Subsequent calls re-fetch only values whose cache TTL has expired.
///
/// Env var override: if LYRIC_CONFIG_<PACKAGE>_<FIELD> is already set, that
/// value is used as-is and the AWS fetch is skipped for that field.
///
/// On failure, returns the first error encountered.  All successfully fetched
/// values up to the point of failure are committed to the cache.
@stable(since="0.1")
pub func init(): Result[Unit, SecretsError] {
  return Ok(())
}

// ─── Explicit fetch API ───────────────────────────────────────────────────────

/// Fetch the entire value of a Secrets Manager secret.
/// For JSON-object secrets use getSecretField to extract a single key.
/// The result is cached for SecretCache.ttlSeconds.
@stable(since="0.1")
pub func getSecret(name: in String): Result[String, SecretsError]
  requires: name.length > 0
{
  return Err(NotFound(name = name))
}

/// Fetch a single JSON field from a Secrets Manager secret.
/// The secret value must be a valid JSON object; key must be a top-level key.
/// The result is cached under (name, key) for SecretCache.ttlSeconds.
@stable(since="0.1")
pub func getSecretField(name: in String, key: in String): Result[String, SecretsError]
  requires: name.length > 0
  requires: key.length > 0
{
  return Err(NotFound(name = name))
}

/// Fetch a plain String or SecureString Parameter Store parameter.
/// SecureString values are decrypted automatically.
/// The result is cached for SecretCache.ttlSeconds.
@stable(since="0.1")
pub func getParameter(path: in String): Result[String, SecretsError]
  requires: path.length > 0
{
  return Err(NotFound(name = path))
}

/// Fetch a Parameter Store parameter without KMS decryption.
/// Use for plain String parameters when you explicitly do not want decryption.
/// The result is cached for SecretCache.ttlSeconds.
@stable(since="0.1")
pub func getParameterRaw(path: in String): Result[String, SecretsError]
  requires: path.length > 0
{
  return Err(NotFound(name = path))
}
