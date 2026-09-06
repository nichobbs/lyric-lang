//! AwsSecrets.Kernel.Net (jvm) — AWS SDK for Java v2 extern boundary.
//!
//! Bridges AwsSecrets to the AWS SDK for Java v2 clients:
//!   software.amazon.awssdk:secretsmanager  — Secrets Manager
//!   software.amazon.awssdk:ssm             — Systems Manager Parameter Store
//!
//! Real bindings (issue #5411): unlike the .NET `aws` feature (see
//! `secrets_kernel_aws.l`'s header for why that one stays NOT_IMPLEMENTED),
//! the JVM v2 SDK's default clients — `SecretsManagerClient`/`SsmClient` —
//! are *synchronous* (`getSecretValue`/`getParameter` are plain blocking
//! interface methods; `SecretsManagerAsyncClient`/`SsmAsyncClient` are
//! separate, unused types here), so there is no async-FFI prerequisite on
//! this target at all. Client/request/response binding follows the same
//! static-factory + fluent-builder auto-FFI idiom already proven by
//! `lyric-web`'s JVM kernel (`JUndertow.builder().addHttpListener(...)
//! .setHandler(...).build()`), verified against the real
//! `software.amazon.awssdk:secretsmanager`/`ssm` 2.25.70 JARs (class
//! shapes inspected via `javap` against the downloaded artifacts).
//!
//! initFromAnnotations():
//!   NOT_IMPLEMENTED. Scanning compiled JVM class metadata for
//!   @secretsManager/@parameterStore annotations at runtime has no
//!   supporting compiler capability anywhere in this codebase (confirmed
//!   by a repo-wide grep as part of issue #5411's investigation — tracked
//!   in issue #6866). Returns a typed error rather than silently
//!   reporting success.
//!
//! fetchSecret(name, key, ttlSeconds):
//!   Calls SecretsManagerClient.getSecretValue().  If key is Some, parses
//!   the SecretString as JSON (Std.Json — pure Lyric, cross-platform since
//!   D-progress-555) and extracts the named field.  Caches under
//!   (name, key) for ttlSeconds using a process-global ConcurrentHashMap
//!   with per-entry expiry timestamps (mirrors the caching idiom used by
//!   `lyric-web`/`lyric-resilience`'s JVM kernels).
//!
//! fetchParameter(path, decrypt, ttlSeconds):
//!   Calls SsmClient.getParameter() with withDecryption = decrypt.
//!   Caches under path for ttlSeconds.
//!
//! Error classification: the AWS SDK's typed exceptions
//!   (ResourceNotFoundException, InvalidParameterException,
//!   DecryptionFailureException, ParameterNotFoundException, ...) all
//!   extend SdkServiceException/RuntimeException, but Lyric's `catch Bug
//!   as b` boundary only exposes a flattened `b.message` string — there is
//!   no typed-exception-hierarchy pattern match across the FFI boundary.
//!   Classification below is therefore best-effort substring matching on
//!   the AWS SDK's own (English, stable-across-versions) exception
//!   messages, falling back to NetworkError for anything unrecognised.
//!   This is a documented limitation, not a silent miscompile: every path
//!   still returns a real `SecretsError`, and NetworkError is always a
//!   safe (if less specific) fallback.
//!
//! Region: resolved from the AWS_DEFAULT_REGION / AWS_REGION env vars or
//! from the EC2 instance metadata service, exactly as the SDK defaults
//! (`SecretsManagerClient.builder().build()` uses the default region and
//! credentials provider chains — no explicit region/credentials wiring
//! needed here).
//!
//! IAM requirements:
//!   The Lambda execution role must have:
//!     secretsmanager:GetSecretValue on target secrets
//!     ssm:GetParameter on target parameters
//!     kms:Decrypt on KMS keys protecting SecureString parameters
//!
//! Maven dependencies (resolved when target = "jvm"):
//!   software.amazon.awssdk:secretsmanager:2.25.x
//!   software.amazon.awssdk:ssm:2.25.x
//!
//! Enabled only when the "jvm" feature flag is active.
//! See docs/35-lambda-library.md §12.3, issue #5411.
@cfg(feature = "jvm")
package AwsSecrets.Kernel.Net

import Std.Core
import Std.Json
import AwsSecrets

// =====================================================================
// Extern types — real AWS SDK for Java v2 classes (verified via javap
// against secretsmanager-2.25.70.jar / ssm-2.25.70.jar).
// =====================================================================
extern type JSecretsManagerClient = "software.amazon.awssdk.services.secretsmanager.SecretsManagerClient"

extern type JGetSecretValueRequest = "software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest"

extern type JGetSecretValueResponse = "software.amazon.awssdk.services.secretsmanager.model.GetSecretValueResponse"

extern type JSsmClient = "software.amazon.awssdk.services.ssm.SsmClient"

extern type JGetParameterRequest = "software.amazon.awssdk.services.ssm.model.GetParameterRequest"

extern type JGetParameterResponse = "software.amazon.awssdk.services.ssm.model.GetParameterResponse"

extern type JParameter = "software.amazon.awssdk.services.ssm.model.Parameter"

// `GetParameterRequest$Builder.withDecryption` takes a boxed
// `java.lang.Boolean` (JVM bytecode has no implicit autoboxing at a call
// site), so a raw Lyric `Bool` cannot be passed directly — box explicitly
// via the same `JBoolean.TRUE`/`FALSE` static-field idiom `lyric-web`'s
// JVM kernel uses for `UndertowOptions.ENABLE_HTTP2`.
extern type JBoolean = "java.lang.Boolean"

func boxBool(b: in Bool): JBoolean {
  if b {
    JBoolean.TRUE
  } else {
    JBoolean.FALSE
  }
}

// java.util.concurrent.ConcurrentHashMap-backed TTL cache — same idiom as
// `lyric-web`/`lyric-resilience`'s JVM kernels (see those files' headers
// for why this needs a rename away from the .NET-side `ConcurrentDict`
// alias, #5443/#5458: this package has both a `_kernel/net` and a
// `_kernel/jvm` source for the SAME package name, selected by feature).
extern type JvmConcurrentDict[K, V] = "java.util.concurrent.ConcurrentHashMap"

@externTarget("java.util.concurrent.ConcurrentHashMap.<init>")
func newConcurrentDict[K, V](): JvmConcurrentDict[K, V] = ()

func cdTryGetValue[K, V](dict: in JvmConcurrentDict[K, V], key: in K, value: out V): Bool {
  value = dict.get(key)
  dict.containsKey(key)
}

func cdPut[K, V](dict: in JvmConcurrentDict[K, V], key: in K, value: in V): Unit {
  val _ = dict.put(key, value)
}

@externTarget("java.lang.System.currentTimeMillis")
func currentTimeMillis(): Long = ()

record CacheEntry {
  value: String
  expiresAtMs: Long
}

val secretCache: JvmConcurrentDict[String, CacheEntry] = newConcurrentDict[String, CacheEntry]()

val parameterCache: JvmConcurrentDict[String, CacheEntry] = newConcurrentDict[String, CacheEntry]()

// Lazily-constructed client singletons: building a real client eagerly
// wires up its connection pool, so building it once per process — not
// once per call — matters for a warm Lambda invocation.
//
// This does NOT reuse the generic `JvmConcurrentDict[K, V]` above: a
// module-level `newConcurrentDict[String, JSecretsManagerClient]()` call
// hits a genuine self-hosted-compiler monomorphisation gap ("an explicit
// type argument does not resolve to a known type in this compilation
// unit") when the type argument is an `extern type` rather than a plain
// Lyric record — `CacheEntry` above (a plain record) monomorphises fine
// at the same call shape, so this is specific to instantiating the
// generic over an extern-typed argument (tracked in #6891). Sidestepping
// it here with two dedicated (non-generic) `ConcurrentHashMap` bindings,
// one per client type, is a two-line-per-type workaround, not a design
// requirement — worth revisiting once the monomorphiser handles this case.
extern type SmClientCache = "java.util.concurrent.ConcurrentHashMap"

@externTarget("java.util.concurrent.ConcurrentHashMap.<init>")
func newSmClientCache(): SmClientCache = ()

func smCacheTryGet(dict: in SmClientCache, key: in String, value: out JSecretsManagerClient): Bool {
  value = dict.get(key)
  dict.containsKey(key)
}

func smCachePut(dict: in SmClientCache, key: in String, value: in JSecretsManagerClient): Unit {
  val _ = dict.put(key, value)
}

extern type SsmClientCache = "java.util.concurrent.ConcurrentHashMap"

@externTarget("java.util.concurrent.ConcurrentHashMap.<init>")
func newSsmClientCache(): SsmClientCache = ()

func ssmCacheTryGet(dict: in SsmClientCache, key: in String, value: out JSsmClient): Bool {
  value = dict.get(key)
  dict.containsKey(key)
}

func ssmCachePut(dict: in SsmClientCache, key: in String, value: in JSsmClient): Unit {
  val _ = dict.put(key, value)
}

val clientCache: SmClientCache = newSmClientCache()

val ssmClientCache: SsmClientCache = newSsmClientCache()

func getSmClient(): JSecretsManagerClient {
  var existing: JSecretsManagerClient = default()
  if smCacheTryGet(clientCache, "client", existing) {
    return existing
  }
  val client = JSecretsManagerClient.builder().build()
  smCachePut(clientCache, "client", client)
  client
}

func getSsmClient(): JSsmClient {
  var existing: JSsmClient = default()
  if ssmCacheTryGet(ssmClientCache, "client", existing) {
    return existing
  }
  val client = JSsmClient.builder().build()
  ssmCachePut(ssmClientCache, "client", client)
  client
}

// =====================================================================
// Error classification — best-effort substring matching on the SDK's own
// exception messages (see the file header's "Error classification" note).
// `.contains` is a builtin String method (also used bare in
// `Std.String.contains`), so no extra import is needed here.
//
// `pub` (not `internal`) is for `secrets_tests.l`'s direct test access
// only — intentionally not `@stable`-advertised, since this substring
// classification is an implementation detail, not a committed public API.
// =====================================================================
pub func classifySecretsError(name: in String, message: in String): AwsSecrets.SecretsError {
  if message.contains("Secrets Manager can't find the specified secret") or message.contains("ResourceNotFoundException") {
    NotFound(name = name)
  } else if message.contains("AccessDenied") or message.contains("not authorized") {
    AccessDenied(name = name, message = message)
  } else if message.contains("DecryptionFailure") or message.contains("decrypt") {
    DecryptionError(name = name, message = message)
  } else {
    NetworkError(name = name, message = message)
  }
}

pub func classifyParameterError(path: in String, message: in String): AwsSecrets.SecretsError {
  if message.contains("ParameterNotFound") {
    NotFound(name = path)
  } else if message.contains("AccessDenied") or message.contains("not authorized") {
    AccessDenied(name = path, message = message)
  } else if message.contains("InvalidKeyId") or message.contains("decrypt") {
    DecryptionError(name = path, message = message)
  } else {
    NetworkError(name = path, message = message)
  }
}

// =====================================================================
// Public entry points.
// =====================================================================
/// NOT_IMPLEMENTED: scanning compiled JVM class metadata for
/// @secretsManager/@parameterStore annotations at runtime has no
/// supporting compiler capability today. See the file header.
@stable(since = "0.1")
pub func initFromAnnotations(ttlSeconds: in Int): Result[Unit, AwsSecrets.SecretsError]
  requires: ttlSeconds >= 0
{
  return Err(
    error = NetworkError(
      name = "initFromAnnotations",
      message = "config-block annotation scanning (@secretsManager/@parameterStore) is not implemented on the jvm feature: the compiler has no runtime metadata-reading capability for custom annotations (issue #6866). Use getSecret/getSecretField/getParameter/getParameterRaw directly, or set the field's env var override for local development."
    )
  )
}

// Pure — no network/client dependency, so it's directly unit-testable
// (see `secrets_tests.l`'s "extractSecretField" cases) independent of a
// live/mocked AWS endpoint.
pub func extractSecretField(
  name: in String, key: in Option[String], secretString: in String
): Result[String, AwsSecrets.SecretsError] {
  match key {
    case None -> Ok(value = secretString)
    case Some(k) -> {
      match Std.Json.tryParseJson(secretString) {
        case Err(msg) -> Err(error = ParseError(name = name, key = k, message = msg))
        case Ok(doc) -> {
          val root = Std.Json.rootElement(doc)
          match Std.Json.tryGetProperty(root, k) {
            case None -> Err(error = ParseError(name = name, key = k, message = "field '" + k + "' not present in secret JSON"))
            case Some(field) -> try {
              Ok(value = Std.Json.getString(field))
            } catch Bug as b {
              Err(error = ParseError(name = name, key = k, message = "field '" + k + "' is not a string: " + b.message))
            }
          }
        }
      }
    }
  }
}

@stable(since = "0.1")
pub func fetchSecret(
  name: in String, key: in Option[String], ttlSeconds: in Int
): Result[String, AwsSecrets.SecretsError]
  requires: name.length > 0
  requires: ttlSeconds >= 0
{
  val cacheKey = match key { case Some(k) -> name + " " + k; case None -> name }

  var cached: CacheEntry = default()
  if ttlSeconds > 0 and cdTryGetValue(secretCache, cacheKey, cached) {
    if currentTimeMillis() < cached.expiresAtMs {
      return Ok(value = cached.value)
    }
  }

  // Wraps client construction too, not just the SDK call: JSecretsManagerClient.builder().build()
  // resolves the region/credentials chain eagerly and throws SdkClientException if it can't
  // (e.g. no AWS_REGION and no instance profile outside a real Lambda environment) — that must
  // come back as a typed Err like every other SDK failure path here, not panic uncaught (#6979).
  val responseResult: Result[JGetSecretValueResponse, AwsSecrets.SecretsError] = try {
    val client = getSmClient()
    val request: JGetSecretValueRequest = JGetSecretValueRequest.builder().secretId(name).build()
    Ok(value = client.getSecretValue(request))
  } catch Bug as b {
    Err(error = classifySecretsError(name, b.message))
  }

  val result: Result[String, AwsSecrets.SecretsError] = match responseResult {
    case Err(e) -> Err(error = e)
    case Ok(response) -> extractSecretField(
      name,
      key,
      response.secretString()
    )
  }

  if ttlSeconds > 0 {
    match result {
      case Ok(v) -> cdPut(
        secretCache,
        cacheKey,
        CacheEntry(value = v, expiresAtMs = currentTimeMillis() + ttlSeconds.toLong() * 1000i64)
      )
      case Err(_) -> ()
    }
  }

  result
}

@stable(since = "0.1")
pub func fetchParameter(path: in String, decrypt: in Bool, ttlSeconds: in Int): Result[String, AwsSecrets.SecretsError]
  requires: path.length > 0
  requires: ttlSeconds >= 0
{
  val cacheKey = path + " " + decrypt.toString()

  var cached: CacheEntry = default()
  if ttlSeconds > 0 and cdTryGetValue(parameterCache, cacheKey, cached) {
    if currentTimeMillis() < cached.expiresAtMs {
      return Ok(value = cached.value)
    }
  }

  // Wraps client construction too — see fetchSecret's identical comment above (#6979).
  val responseResult: Result[JGetParameterResponse, AwsSecrets.SecretsError] = try {
    val client = getSsmClient()
    val request: JGetParameterRequest = JGetParameterRequest.builder().name(path).withDecryption(boxBool(decrypt)).build()
    Ok(value = client.getParameter(request))
  } catch Bug as b {
    Err(error = classifyParameterError(path, b.message))
  }

  val result: Result[String, AwsSecrets.SecretsError] = match responseResult {
    case Err(e) -> Err(error = e)
    case Ok(response) -> {
      val parameter: JParameter = response.parameter()
      Ok(value = parameter.value())
    }
  }

  if ttlSeconds > 0 {
    match result {
      case Ok(v) -> cdPut(
        parameterCache,
        cacheKey,
        CacheEntry(value = v, expiresAtMs = currentTimeMillis() + ttlSeconds.toLong() * 1000i64)
      )
      case Err(_) -> ()
    }
  }

  result
}
