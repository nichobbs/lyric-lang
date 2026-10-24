//! AwsSecrets — AWS Secrets Manager and Parameter Store integration for Lyric.
//!
//! Stability: @stable(since="0.1") — the public API is covered by
//! SemVer; the AWS SDK v3 calls behind it are wrapped at the
//! kernel boundary and tracked in docs/17-axiom-audit.md.
//!
//! Primary usage: config-block annotation support.
//!
//!   Apply @secretsManager or @parameterStore to @sensitive fields in a config
//!   block to declare that the field's value should come from AWS instead of
//!   (or in addition to) an env var.  Then call AwsSecrets.init() once at
//!   process startup, BEFORE the first read of any annotated config block
//!   (and before Lambda.serve() or Web.start()).
//!
//!   init() reads the annotations the compiler embedded (Std.AnnotationMeta),
//!   fetches each annotated field's value from Secrets Manager / Parameter
//!   Store, and registers it with Std.ConfigOverride under the field's
//!   LYRIC_CONFIG_<PACKAGE>_<BLOCK>_<FIELD> name (D230).  A config block is
//!   initialised once, on its first access, and that initialiser consults the
//!   override store before the environment, so the block then reads the
//!   fetched value as it would an env var.  The value is never written to the
//!   process environment, so child processes do not inherit it.
//!
//!   Env var override: if LYRIC_CONFIG_<PACKAGE>_<BLOCK>_<FIELD> is set, it
//!   takes precedence over the secret and the AWS fetch is skipped for that
//!   field.  This enables local development without AWS credentials -- set
//!   env vars locally and use real secrets in production.
//!
//! Annotation reference:
//!
//!   @secretsManager("secret-name")
//!     Fetch the entire secret value (for plain-string secrets).
//!
//!   @secretsManager("secret-name", key = "field-name")
//!     Fetch a single JSON field from a structured secret.
//!     The secret value must be a valid JSON object.
//!
//!   @parameterStore("/param/path")
//!     Fetch a Parameter Store parameter (String or SecureString; SecureString
//!     is decrypted automatically using the parameter's KMS key).
//!
//! Example:
//!
//!   import AwsSecrets
//!
//!   config Database {
//!     host: String = "localhost"
//!     port: Int    = 5432
//!     @sensitive
//!     @secretsManager("my-service/prod", key = "dbPassword")
//!     password: String
//!   }
//!
//!   config Auth {
//!     @sensitive
//!     @secretsManager("my-service/prod", key = "jwtSecret")
//!     jwtSecret: String
//!     @sensitive
//!     @parameterStore("/my-service/signing-key")
//!     signingKey: String
//!   }
//!
//!   func main(): Int {
//!     // Before anything reads Database.* or Auth.*.
//!     match AwsSecrets.init() {
//!       Ok(_)    => Lambda.serve(Lambda.newApp() |> Lambda.withRouter(router))
//!       Err(err) => {
//!         Std.Core.log("ERROR", AwsSecrets.errorMessage(err))
//!         return 1
//!       }
//!     }
//!     return 0
//!   }
//!
//! Secondary usage: explicit imperative fetch.
//!
//!   Use getSecret / getSecretField / getParameter / getSecureParameter for
//!   one-off fetches inside handler bodies where a config field is not
//!   appropriate (e.g. fetching a per-tenant secret at request time).
//!
//! Caching:
//!   Values are cached in process memory for SecretCache.ttlSeconds (default
//!   5 minutes).  On a warm Lambda invocation the cached value is returned
//!   without an AWS API call.  Set ttlSeconds = 0 to disable caching.
//!   Match the TTL to your secret rotation period: a safe default is
//!   ttlSeconds < rotationPeriodSeconds / 6.
//!
//! Runtime env vars:
//!   LYRIC_CONFIG_AWSSECRETS_SECRETCACHE_TTLSECONDS  — cache TTL (default: 300)
//!
//! See docs/35-lambda-library.md §6, decision log D063.
@runtime_checked
@io
package AwsSecrets

import Std.Core
import Std.Collections
import Std.Environment as Env
import Std.AnnotationMeta as Meta
import Std.ConfigOverride as Override
import AwsSecrets.Kernel.Net as SecretsKernel

// ─── Annotations ─────────────────────────────────────────────────────────────
// @secretsManager and @parameterStore are user-facing annotation names.
// Bootstrap does not support pub annotation declarations; these are documented
// in the module header and enforced at runtime by the kernel's initFromAnnotations.
// ─── SecretsError ─────────────────────────────────────────────────────────────
/// Typed error union for Secrets Manager and Parameter Store failures.
@stable(since = "0.1")
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
  /// The secret is stored as raw binary (Secrets Manager's SecretBinary)
  /// rather than a UTF-8 string (SecretString). This API only supports
  /// string-valued secrets — retrying will never succeed for a binary
  /// secret, unlike NetworkError.
  case BinaryValueUnsupported(name: String)
  /// The requested capability is not available on this backend (for
  /// example config-block annotation scanning, issue #6866).  Retrying
  /// will never succeed, unlike NetworkError.
  case NotImplemented(feature: String, message: String)
  /// A configuration value (for example SecretCache.ttlSeconds, read from
  /// its env var) is outside its allowed range.  Nothing was fetched.
  case InvalidConfig(field: String, message: String)
}

/// Human-readable message for logging.
@stable(since = "0.1")
pub func errorMessage(err: in SecretsError): String {
  match err {
    case NotFound(name) -> "Secret not found: " + name
    case AccessDenied(name, msg) -> "Access denied for " + name + ": " + msg
    case DecryptionError(name, msg) -> "Decryption failed for " + name + ": " + msg
    case ParseError(name, key, msg) -> "Parse error for " + name + "[" + key + "]: " + msg
    case NetworkError(name, msg) -> "Network error fetching " + name + ": " + msg
    case BinaryValueUnsupported(name) -> "Secret '" + name +
      "' is stored as binary (SecretBinary), not a string; this API only supports string-valued secrets"
    case NotImplemented(feature, msg) -> "Not implemented: " + feature + ": " + msg
    case InvalidConfig(field, msg) -> "Invalid configuration " + field + ": " + msg
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
/// ttlSeconds must be at most maxCacheTtlSeconds() (86400, one day) so a
/// rotated secret is always picked up within a day; a negative or larger
/// value makes every call return InvalidConfig instead of fetching.
///
/// Set TTL to a fraction of your secret rotation period.  For example, if
/// rotating every 24 hours, a TTL of 300s (5 minutes) ensures stale values
/// are refreshed well within the rotation window.
config SecretCache {
  ttlSeconds: Int = 300
}

// ─── Initialisation ───────────────────────────────────────────────────────────
/// Fetch all @secretsManager and @parameterStore annotated config block fields
/// and register each value with Std.ConfigOverride, so the config block reads
/// it when it is first accessed.
///
/// Must be called once at process startup, before the first read of any
/// annotated config block: a block is initialised once, on first access, and
/// a value registered after that is not seen by it.  Subsequent calls
/// re-fetch only values whose cache TTL has expired.
///
/// Env var override: if LYRIC_CONFIG_<PACKAGE>_<BLOCK>_<FIELD> is already set,
/// that value is used as-is and the AWS fetch is skipped for that field.
///
/// On failure, returns the first error encountered.  Every value fetched up
/// to the point of failure stays registered.
@stable(since = "0.1")
pub func init(): Result[Unit, SecretsError] {
  match checkCacheTtl(SecretCache.ttlSeconds) {
    case Err(e) -> Err(error = e)
    case Ok(ttl) -> SecretsKernel.initFromAnnotations(ttl)
  }
}

/// Upper bound for SecretCache.ttlSeconds: one day.
@stable(since = "0.1")
pub func maxCacheTtlSeconds(): Int = 86400

/// True when ttlSeconds is an allowed cache TTL (0..maxCacheTtlSeconds()).
@stable(since = "0.1")
@pure
pub func isValidCacheTtl(ttlSeconds: in Int): Bool = ttlSeconds >= 0 and ttlSeconds <= 86400

/// Ok(ttlSeconds) when it is an allowed cache TTL, else InvalidConfig.
/// SecretCache.ttlSeconds comes from an env var, so an out-of-range value
/// is reported as an error rather than a contract failure.
@stable(since = "0.1")
pub func checkCacheTtl(ttlSeconds: in Int): Result[Int, SecretsError]
  ensures: match result { case Ok(t) -> isValidCacheTtl(t); case Err(_) -> true }
{
  if isValidCacheTtl(ttlSeconds) {
    return Ok(value = ttlSeconds)
  }
  Err(
    error = InvalidConfig(
      field = "SecretCache.ttlSeconds",
      message = "must be between 0 and " + maxCacheTtlSeconds().toString() + " seconds, got " +
        ttlSeconds.toString()
    )
  )
}

// ─── Explicit fetch API ───────────────────────────────────────────────────────
/// Fetch the entire value of a Secrets Manager secret.
/// For JSON-object secrets use getSecretField to extract a single key.
/// The result is cached for SecretCache.ttlSeconds.
@stable(since = "0.1")
pub func getSecret(name: in String): Result[String, SecretsError]
  requires: name.length > 0
{
  match checkCacheTtl(SecretCache.ttlSeconds) {
    case Err(e) -> Err(error = e)
    case Ok(ttl) -> SecretsKernel.fetchSecret(name, None, ttl)
  }
}

/// Fetch a single JSON field from a Secrets Manager secret.
/// The secret value must be a valid JSON object; key must be a top-level key.
/// The result is cached under (name, key) for SecretCache.ttlSeconds.
@stable(since = "0.1")
pub func getSecretField(name: in String, key: in String): Result[String, SecretsError]
  requires: name.length > 0
  requires: key.length > 0
{
  match checkCacheTtl(SecretCache.ttlSeconds) {
    case Err(e) -> Err(error = e)
    case Ok(ttl) -> SecretsKernel.fetchSecret(name, Some(key), ttl)
  }
}

/// Fetch a plain String or SecureString Parameter Store parameter.
/// SecureString values are decrypted automatically.
/// The result is cached for SecretCache.ttlSeconds.
@stable(since = "0.1")
pub func getParameter(path: in String): Result[String, SecretsError]
  requires: path.length > 0
{
  match checkCacheTtl(SecretCache.ttlSeconds) {
    case Err(e) -> Err(error = e)
    case Ok(ttl) -> SecretsKernel.fetchParameter(path, true, ttl)
  }
}

/// Fetch a Parameter Store parameter without KMS decryption.
/// Use for plain String parameters when you explicitly do not want decryption.
/// The result is cached for SecretCache.ttlSeconds.
@stable(since = "0.1")
pub func getParameterRaw(path: in String): Result[String, SecretsError]
  requires: path.length > 0
{
  match checkCacheTtl(SecretCache.ttlSeconds) {
    case Err(e) -> Err(error = e)
    case Ok(ttl) -> SecretsKernel.fetchParameter(path, false, ttl)
  }
}

// ─── Annotation-driven registration ──────────────────────────────────────────
func fieldLabel(f: in Meta.AnnotatedField): String = f.configName + "." + f.fieldName

func hasEnvValue(key: in String): Bool {
  match Env.getVar(key) {
    case Ok(v) -> v.length > 0
    case Err(_) -> false
  }
}

func invalidAnnotation(f: in Meta.AnnotatedField, what: in String): SecretsError {
  InvalidConfig(field = fieldLabel(f), message = "@" + f.annotationName + " " + what)
}

func fetchAnnotated(
  f: in Meta.AnnotatedField,
  fetchSecret: in (String, Option[String]) -> Result[String, SecretsError],
  fetchParameter: in (String) -> Result[String, SecretsError],
): Result[String, SecretsError] {
  match Meta.positionalArg(f, 0) {
    case None -> Err(error = invalidAnnotation(f, "needs its secret name or parameter path as the first argument"))
    case Some(target) -> {
      if target.length == 0 {
        return Err(error = invalidAnnotation(f, "has an empty secret name or parameter path"))
      }
      if f.annotationName == "secretsManager" {
        fetchSecret(target, Meta.namedArg(f, "key"))
      } else {
        fetchParameter(target)
      }
    }
  }
}

func registerError(f: in Meta.AnnotatedField, err: in Override.ConfigOverrideError): SecretsError {
  match err {
    case Unsupported(reason) -> NotImplemented(feature = "initFromAnnotations", message = reason)
    case _ -> InvalidConfig(field = fieldLabel(f), message = Override.errorMessage(err))
  }
}

/// Fetch the value of each field in `fields` (each carrying @secretsManager
/// or @parameterStore) through the two fetch functions and register it with
/// Std.ConfigOverride under the field's environment-variable name.  A field
/// whose environment variable is already set is skipped.  This is the engine
/// behind init(), exposed so a program with its own secret source, or a test,
/// can drive it without AWS.
///
/// # Errors
/// - `InvalidConfig`: an annotation lacks its name/path argument, a field
///   carries both annotations, or the fetched value cannot be registered.
/// - `ParseError`: a fetched value is empty (an empty override means none).
/// - `NotImplemented`: the target has no config-override store (native).
/// - Anything a fetch function returns.
@stable(since = "0.1")
pub func registerSecrets(
  fields: in List[Meta.AnnotatedField],
  fetchSecret: in (String, Option[String]) -> Result[String, SecretsError],
  fetchParameter: in (String) -> Result[String, SecretsError],
): Result[Unit, SecretsError] {
  val seen: List[String] = newList()
  var i = 0
  while i < fields.count {
    val f = fields[i]
    if seen.contains(f.envVar) {
      return Err(error = invalidAnnotation(f, "conflicts with another secret annotation on the same field"))
    }
    seen.add(f.envVar)
    if not hasEnvValue(f.envVar) {
      match fetchAnnotated(f, fetchSecret, fetchParameter) {
        case Err(e) -> return Err(error = e)
        case Ok(value) -> {
          if value.length == 0 {
            return Err(
              error = ParseError(
                name = fieldLabel(f),
                key = f.envVar,
                message = "the fetched value is empty, which cannot be registered as a config override"
              )
            )
          }
          match Override.setConfigOverride(f.envVar, value) {
            case Err(e) -> return Err(error = registerError(f, e))
            case Ok(_) -> ()
          }
        }
      }
    }
    i = i + 1
  }
  Ok(value = ())
}

func isSecretAnnotation(f: in Meta.AnnotatedField): Bool {
  f.annotationName == "secretsManager" or f.annotationName == "parameterStore"
}

/// Scan the embedded annotation metadata for @secretsManager and
/// @parameterStore fields and register their values through the kernel's
/// fetch functions.  The body of the aws and jvm kernels'
/// `initFromAnnotations`.
@stable(since = "0.1")
pub func registerAnnotated(ttlSeconds: in Int): Result[Unit, SecretsError]
  requires: ttlSeconds >= 0
{
  match Meta.allAnnotatedFields() {
    case Err(Unsupported(reason)) -> Err(error = NotImplemented(feature = "initFromAnnotations", message = reason))
    case Err(Malformed(message)) -> Err(error = InvalidConfig(field = "Lyric.AnnotationMeta", message = message))
    case Ok(all) -> {
      val secretFields: List[Meta.AnnotatedField] = newList()
      var i = 0
      while i < all.count {
        if isSecretAnnotation(all[i]) {
          secretFields.add(all[i])
        }
        i = i + 1
      }
      registerSecrets(
        secretFields,
        { name: String, key: Option[String] -> SecretsKernel.fetchSecret(name, key, ttlSeconds) },
        { path: String -> SecretsKernel.fetchParameter(path, true, ttlSeconds) }
      )
    }
  }
}
