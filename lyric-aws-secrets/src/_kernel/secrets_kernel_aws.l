//! AwsSecrets.Kernel.Net (aws) — AWS SDK for .NET v3 extern boundary.
//!
//! Bridges AwsSecrets to the AWS SDK for .NET v3 clients:
//!   AWSSDK.SecretsManager             — Secrets Manager
//!   AWSSDK.SimpleSystemsManagement    — Systems Manager Parameter Store
//!
//! Real bindings (issue #6864, the async-API-shape follow-up to #5411's
//! JVM-only shipment): #5411's original claim that no `extern type` +
//! auto-FFI precedent exists in this repo for a `Task<T>`-returning
//! BCL/SDK async call was wrong — `Std.HttpHost`
//! (`lyric-stdlib/std/_kernel/http_host.l`) already binds
//! `HttpClient.SendAsync` this exact way (`@externTarget("...") async func
//! ...(...): T = ()`, `await`ed by callers), and the AWS .NET SDK's
//! `AmazonSecretsManagerClient.GetSecretValueAsync`/
//! `AmazonSimpleSystemsManagementClient.GetParameterAsync` are the same
//! shape (plain instance methods, non-generic, returning `Task<TResponse>`;
//! verified via .NET reflection against the restored
//! `AWSSDK.SecretsManager`/`AWSSDK.SimpleSystemsManagement` 3.7.400
//! assemblies).
//!
//! What actually unblocks this (the real question #6864 asks): does
//! `AwsSecrets`'s public API have to become `async func` to await a real
//! `Task<T>`-returning SDK call?  No.  The self-hosted MSIL emitter already
//! supports `await` inside a PLAIN (non-`async`) function — when the
//! enclosing function is not itself an async state machine, `EAwait`
//! lowers to a blocking `GetAwaiter().GetResult()` shim instead of the
//! suspend/resume protocol (`Lyric.AwaitHoist`'s own module doc: "plain
//! functions and lambdas resolve `await` with a blocking
//! `GetAwaiter().GetResult()` shim that has no suspension"; see
//! `emitBlockingAwait` in `lyric-compiler/msil/codegen.l`, exercised by
//! `async_sm_self_test.l`/`async_spawn_self_test.l`'s existing MSIL-path
//! coverage). `AwsSecrets`'s public surface therefore stays exactly as
//! synchronous as it always was — `init()`/`getSecret()`/
//! `getSecretField()`/`getParameter()`/`getParameterRaw()` are unchanged,
//! `func main(): Int` and every `lyric-lambda` `DirectHandler` keep
//! working with zero cascading changes. `fetchSecret`/`fetchParameter`
//! below stay plain `func`s and simply `await` the extern async calls.
//!
//! Client/request/response binding follows the same explicit
//! `extern type` + `@externTarget` idiom `Std.HttpHost` already uses
//! (ctor + `set_<Prop>` for writes, bare `<Prop>` for reads — auto-FFI
//! resolves a bare property name to its getter even when a setter also
//! exists, per `HttpResponseMessage.StatusCode`'s established precedent).
//! `GetSecretValueAsync`/`GetParameterAsync` take an explicit
//! `CancellationToken` argument (verified via reflection: these are
//! single methods with a C# *optional* trailing parameter, not a genuine
//! CLR method-overload pair the way `HttpClient.SendAsync` is — the CLR
//! itself has no concept of an omittable argument, so the token is always
//! passed explicitly here via `Std.Task.noCancellation()`).
//!
//! initFromAnnotations():
//!   NOT_IMPLEMENTED — separate, genuine compiler gap (issue #6866):
//!   scanning a compiled DLL's config-block metadata for
//!   @secretsManager/@parameterStore annotations at runtime has no
//!   supporting capability anywhere in the compiler or runtime (confirmed
//!   by a repo-wide grep as part of #5411's original investigation).
//!
//! fetchSecret(name, key, ttlSeconds):
//!   Calls AmazonSecretsManagerClient.GetSecretValueAsync. If key is Some,
//!   parses the SecretString as JSON (Std.Json) and extracts the named
//!   field. A binary-only secret (SecretString null, SecretBinary set)
//!   comes back as a typed BinaryValueUnsupported, mirroring the jvm
//!   kernel's #7047 fix. Caches under (name, key) for ttlSeconds using a
//!   process-global ConcurrentDictionary with per-entry expiry timestamps
//!   (same idiom `lyric-web`/`lyric-resilience`'s .NET kernels use).
//!
//! fetchParameter(path, decrypt, ttlSeconds):
//!   Calls AmazonSimpleSystemsManagementClient.GetParameterAsync with
//!   WithDecryption = decrypt. Caches under path for ttlSeconds.
//!
//! Error classification: the AWS SDK's typed exceptions
//!   (ResourceNotFoundException, ParameterNotFoundException,
//!   AccessDeniedException, DecryptionFailureException, ...) all extend
//!   AmazonServiceException/AmazonClientException, but Lyric's `catch Bug
//!   as b` boundary only exposes a flattened `b.message` string (the raw
//!   `Exception.Message`, confirmed against the MSIL emitter's `.message`
//!   accessor) — there is no typed-exception-hierarchy pattern match
//!   across the FFI boundary, exactly the same constraint the jvm kernel's
//!   header documents. Classification below mirrors that kernel's
//!   best-effort substring matching against the SDK's own service-side
//!   error messages (shared verbatim across every AWS SDK language binding
//!   — the message text originates from the service's JSON error
//!   response, not from SDK-generated wording), falling back to
//!   NetworkError for anything unrecognised. This is a documented
//!   limitation, not a silent miscompile: every path still returns a real
//!   `SecretsError`.
//!
//! Region/credentials: resolved from the default AWS SDK for .NET chain
//!   (environment variables, shared config/credentials files, EC2/ECS/
//!   Lambda instance metadata) — the parameterless client constructors
//!   below (`new AmazonSecretsManagerClient()` / `new
//!   AmazonSimpleSystemsManagementClient()`) use exactly this default
//!   chain, mirroring the jvm kernel's `builder().build()`.
//!
//! IAM requirements:
//!   The Lambda execution role must have:
//!     secretsmanager:GetSecretValue on target secrets
//!     ssm:GetParameter on target parameters
//!     kms:Decrypt on KMS keys protecting SecureString parameters
//!
//! NuGet dependencies (resolved when target = "aws"):
//!   AWSSDK.SecretsManager 3.7.x
//!   AWSSDK.SimpleSystemsManagement 3.7.x
//!
//! Enabled only when the "aws" feature flag is active.
//! See docs/35-lambda-library.md §6, issue #6864 (this file), issue #5411
//! (the parent investigation), docs/03-decision-log.md D-progress-877.
@cfg(feature = "aws")
package AwsSecrets.Kernel.Net

import Std.Core
import Std.Json
import Std.Task
import Std.Time
import AwsSecrets

// =====================================================================
// Extern types — real AWS SDK for .NET v3 classes (verified via .NET
// reflection against the restored AWSSDK.SecretsManager 3.7.400 /
// AWSSDK.SimpleSystemsManagement 3.7.400 assemblies).
// =====================================================================
extern type AmazonSecretsManagerClient = "Amazon.SecretsManager.AmazonSecretsManagerClient"

extern type GetSecretValueRequest = "Amazon.SecretsManager.Model.GetSecretValueRequest"

extern type GetSecretValueResponse = "Amazon.SecretsManager.Model.GetSecretValueResponse"

extern type AmazonSimpleSystemsManagementClient = "Amazon.SimpleSystemsManagement.AmazonSimpleSystemsManagementClient"

extern type GetParameterRequest = "Amazon.SimpleSystemsManagement.Model.GetParameterRequest"

extern type GetParameterResponse = "Amazon.SimpleSystemsManagement.Model.GetParameterResponse"

extern type SsmParameter = "Amazon.SimpleSystemsManagement.Model.Parameter"

// =====================================================================
// Primitive externs (private to this kernel file) — client/request/
// response construction and access, mirroring Std.HttpHost's idiom.
// =====================================================================
@externTarget("Amazon.SecretsManager.AmazonSecretsManagerClient..ctor")
func newSecretsManagerClient(): AmazonSecretsManagerClient = ()

@externTarget("Amazon.SecretsManager.Model.GetSecretValueRequest..ctor")
func newGetSecretValueRequest(): GetSecretValueRequest = ()

@externInstance
@externTarget("Amazon.SecretsManager.Model.GetSecretValueRequest.set_SecretId")
func setSecretId(req: in GetSecretValueRequest, id: in String): Unit = ()

@externInstance
@externTarget("Amazon.SecretsManager.Model.GetSecretValueResponse.SecretString")
func secretStringOf(response: in GetSecretValueResponse): String = ()

// `@externTarget async func` with a T-declared (not Task<T>) return type —
// the same shape as Std.HttpHost's `clientSendAsyncCancel`. The Task
// unwrapping happens as part of the call itself; `await` below is legal
// (and required by the mode checker for an async-declared callee) inside
// a plain `func` and resolves via the MSIL backend's blocking-await path.
@externInstance
@externTarget("Amazon.SecretsManager.AmazonSecretsManagerClient.GetSecretValueAsync")
async func getSecretValueAsyncExtern(
  client: in AmazonSecretsManagerClient,
  request: in GetSecretValueRequest,
  token: in CancellationToken,
): GetSecretValueResponse = ()

@externTarget("Amazon.SimpleSystemsManagement.AmazonSimpleSystemsManagementClient..ctor")
func newSsmClient(): AmazonSimpleSystemsManagementClient = ()

@externTarget("Amazon.SimpleSystemsManagement.Model.GetParameterRequest..ctor")
func newGetParameterRequest(): GetParameterRequest = ()

@externInstance
@externTarget("Amazon.SimpleSystemsManagement.Model.GetParameterRequest.set_Name")
func setParameterName(req: in GetParameterRequest, name: in String): Unit = ()

@externInstance
@externTarget("Amazon.SimpleSystemsManagement.Model.GetParameterRequest.set_WithDecryption")
func setWithDecryption(req: in GetParameterRequest, v: in Bool): Unit = ()

@externInstance
@externTarget("Amazon.SimpleSystemsManagement.Model.GetParameterResponse.Parameter")
func parameterOf(response: in GetParameterResponse): SsmParameter = ()

@externInstance
@externTarget("Amazon.SimpleSystemsManagement.Model.Parameter.Value")
func parameterValueOf(p: in SsmParameter): String = ()

@externInstance
@externTarget("Amazon.SimpleSystemsManagement.AmazonSimpleSystemsManagementClient.GetParameterAsync")
async func getParameterAsyncExtern(
  client: in AmazonSimpleSystemsManagementClient,
  request: in GetParameterRequest,
  token: in CancellationToken,
): GetParameterResponse = ()

// java.util.concurrent.ConcurrentHashMap's .NET counterpart — same TTL-cache
// idiom `lyric-web`/`lyric-resilience`'s .NET kernels already use.
extern type NetConcurrentDict[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDict[K, V](): NetConcurrentDict[K, V] = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdTryGetValue[K, V](dict: in NetConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.set_Item")
func cdSetItem[K, V](dict: in NetConcurrentDict[K, V], key: in K, value: in V): Unit = ()

func cdPut[K, V](dict: in NetConcurrentDict[K, V], key: in K, value: in V): Unit {
  cdSetItem(dict, key, value)
}

extern type Obj = "System.Object"

record CacheEntry {
  value: String
  expiresAtMs: Long
}

val secretCache: NetConcurrentDict[String, CacheEntry] = newConcurrentDict[String, CacheEntry]()

val parameterCache: NetConcurrentDict[String, CacheEntry] = newConcurrentDict[String, CacheEntry]()

// Lazily-constructed client singletons: building a real client eagerly
// wires up its connection pool, so building it once per process — not
// once per call — matters for a warm Lambda invocation. Mirrors the jvm
// kernel's `getSmClient`/`getSsmClient`, but the workaround shape differs
// from that kernel's #6891 note: JVM generics are erased, so a raw
// (type-argument-free) `ConcurrentHashMap` works directly. .NET generics
// are reified — `ConcurrentDictionary`2` with NO type arguments cannot be
// constructed at all (confirmed directly: `newConcurrentDict[String,
// AmazonSecretsManagerClient]()` hits the identical #6891 monomorphisation
// gap this kernel is also blocked on, "an explicit type argument does not
// resolve to a known type in this compilation unit," for the same reason
// — an extern-typed generic argument). The fix here is to name the
// bracketed generic instantiation directly in the `extern type` target
// string (the CLR's `Type`N[[Arg1],[Arg2]]` syntax): the MSIL codegen
// erases any extern-type FQN containing `[` to `object` wholesale (the
// same object-erasure escape hatch `lyric-grpc`'s `NetGrpcChannelDict`
// already uses; see `typeExprToMsilCtx` in `lyric-compiler/msil/codegen.l`),
// so no Lyric-side type parameter — and therefore no monomorphisation —
// is needed at all. Member calls on the erased value still route through
// `emitGenericExternMember`, which builds the real closed GENERICINST
// TypeSpec and `castclass`es the receiver.
extern type SmClientCache = "System.Collections.Concurrent.ConcurrentDictionary`2[[System.String],[Amazon.SecretsManager.AmazonSecretsManagerClient]]"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newSmClientCache(): SmClientCache = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func smCacheTryGet(dict: in SmClientCache, key: in String, value: out AmazonSecretsManagerClient): Bool = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.set_Item")
func smCacheSetItem(dict: in SmClientCache, key: in String, value: in AmazonSecretsManagerClient): Unit = ()

func smCachePut(dict: in SmClientCache, key: in String, value: in AmazonSecretsManagerClient): Unit {
  smCacheSetItem(dict, key, value)
}

extern type SsmClientCache = "System.Collections.Concurrent.ConcurrentDictionary`2[[System.String],[Amazon.SimpleSystemsManagement.AmazonSimpleSystemsManagementClient]]"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newSsmClientCache(): SsmClientCache = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func ssmCacheTryGet(dict: in SsmClientCache, key: in String, value: out AmazonSimpleSystemsManagementClient): Bool = ()

@externInstance
@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.set_Item")
func ssmCacheSetItem(dict: in SsmClientCache, key: in String, value: in AmazonSimpleSystemsManagementClient): Unit = ()

func ssmCachePut(dict: in SsmClientCache, key: in String, value: in AmazonSimpleSystemsManagementClient): Unit {
  ssmCacheSetItem(dict, key, value)
}

val clientCache: SmClientCache = newSmClientCache()

val ssmClientCache: SsmClientCache = newSsmClientCache()

func getSmClient(): AmazonSecretsManagerClient {
  var existing: AmazonSecretsManagerClient = default()
  if smCacheTryGet(clientCache, "client", existing) {
    return existing
  }
  val client = newSecretsManagerClient()
  smCachePut(clientCache, "client", client)
  client
}

func getSsmClient(): AmazonSimpleSystemsManagementClient {
  var existing: AmazonSimpleSystemsManagementClient = default()
  if ssmCacheTryGet(ssmClientCache, "client", existing) {
    return existing
  }
  val client = newSsmClient()
  ssmCachePut(ssmClientCache, "client", client)
  client
}

// =====================================================================
// Error classification — best-effort substring matching on the SDK's own
// (service-side, language-independent) exception messages; see the file
// header's "Error classification" note. Mirrors the jvm kernel's
// classifySecretsError/classifyParameterError exactly.
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
/// NOT_IMPLEMENTED: scanning compiled DLL config-block metadata for
/// @secretsManager/@parameterStore annotations at runtime has no
/// supporting compiler capability today. See the file header (issue
/// #6866 — a separate, genuine compiler gap, unrelated to #6864's
/// async-API-shape question this file otherwise resolves).
@stable(since = "0.1")
pub func initFromAnnotations(ttlSeconds: in Int): Result[Unit, AwsSecrets.SecretsError]
  requires: ttlSeconds >= 0
{
  return Err(
    error = NotImplemented(
      feature = "initFromAnnotations",
      message = "config-block annotation scanning (@secretsManager/@parameterStore) is not implemented on the aws feature: the compiler has no runtime metadata-reading capability for custom annotations (issue #6866). Use getSecret/getSecretField/getParameter/getParameterRaw directly, or set the field's env var override for local development."
    )
  )
}

// Pure — no network/client dependency, so it's directly unit-testable
// independent of a live/mocked AWS endpoint. Identical logic to the jvm
// kernel's extractSecretField.
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

// Pure — directly unit-testable independent of a live/mocked AWS endpoint.
//
// A Secrets Manager secret stores its value as EITHER SecretString OR
// SecretBinary, never both — `response.SecretString` is a real .NET
// `null` for a binary-only secret. Rather than pass that null straight
// into extractSecretField (which would wrap it as `Ok(value = null)` for
// the key=None path), the null check happens once at the call site in
// fetchSecret and is converted to `None` here — mirrors the jvm kernel's
// identical #7047 fix, same decision logic, no FFI access needed to test.
pub func extractSecretValue(
  name: in String, key: in Option[String], secretStringOpt: in Option[String]
): Result[String, AwsSecrets.SecretsError] {
  match secretStringOpt {
    case None -> Err(error = BinaryValueUnsupported(name = name))
    case Some(secretString) -> extractSecretField(name, key, secretString)
  }
}

// Pure — directly unit-testable independent of a live/mocked AWS endpoint.
//
// Same length-prefixed, tag-disambiguated encoding as the jvm kernel's
// secretCacheKeyFor (#7046): a plain `name + " " + k` join let
// getSecret("foo bar") (key=None) and getSecretField("foo", "bar")
// (name="foo", key=Some("bar")) both hash to "foo bar", so one call could
// be served the other's cached secret.
pub func secretCacheKeyFor(name: in String, key: in Option[String]): String {
  match key {
    case None -> "N:" + name
    case Some(k) -> "S" + name.length.toString() + ":" + name + ":" + k
  }
}

@stable(since = "0.1")
pub func fetchSecret(
  name: in String, key: in Option[String], ttlSeconds: in Int
): Result[String, AwsSecrets.SecretsError]
  requires: name.length > 0
  requires: ttlSeconds >= 0
{
  val cacheKey = secretCacheKeyFor(name, key)

  var cached: CacheEntry = default()
  if ttlSeconds > 0 and cdTryGetValue(secretCache, cacheKey, cached) {
    if Std.Time.nowEpochMillis() < cached.expiresAtMs {
      return Ok(value = cached.value)
    }
  }

  // Wraps client construction too, not just the SDK call: `new
  // AmazonSecretsManagerClient()` resolves the region/credentials chain
  // eagerly and throws if it can't (e.g. no AWS_REGION and no instance
  // profile outside a real Lambda environment) — that must come back as a
  // typed Err like every other SDK failure path here, not panic uncaught
  // (mirrors the jvm kernel's #6979 fix).
  val responseResult: Result[GetSecretValueResponse, AwsSecrets.SecretsError] = try {
    val client = getSmClient()
    val request = newGetSecretValueRequest()
    setSecretId(request, name)
    Ok(value = await getSecretValueAsyncExtern(client, request, noCancellation()))
  } catch Bug as b {
    Err(error = classifySecretsError(name, b.message))
  }

  val result: Result[String, AwsSecrets.SecretsError] = match responseResult {
    case Err(e) -> Err(error = e)
    case Ok(response) -> {
      val rawSecretString = secretStringOf(response)
      val secretStringOpt: Option[String] = if Obj.ReferenceEquals(rawSecretString, default()) {
        None
      } else {
        Some(rawSecretString)
      }
      extractSecretValue(name, key, secretStringOpt)
    }
  }

  if ttlSeconds > 0 {
    match result {
      case Ok(v) -> cdPut(
        secretCache,
        cacheKey,
        CacheEntry(value = v, expiresAtMs = Std.Time.nowEpochMillis() + ttlSeconds.toLong() * 1000i64)
      )
      case Err(_) -> ()
    }
  }

  result
}

// Pure — directly unit-testable. Same length-prefixed encoding as
// secretCacheKeyFor above.
pub func parameterCacheKeyFor(path: in String, decrypt: in Bool): String {
  "P" + path.length.toString() + ":" + path + ":" + decrypt.toString()
}

@stable(since = "0.1")
pub func fetchParameter(path: in String, decrypt: in Bool, ttlSeconds: in Int): Result[String, AwsSecrets.SecretsError]
  requires: path.length > 0
  requires: ttlSeconds >= 0
{
  val cacheKey = parameterCacheKeyFor(path, decrypt)

  var cached: CacheEntry = default()
  if ttlSeconds > 0 and cdTryGetValue(parameterCache, cacheKey, cached) {
    if Std.Time.nowEpochMillis() < cached.expiresAtMs {
      return Ok(value = cached.value)
    }
  }

  // Wraps client construction too — see fetchSecret's identical comment above.
  val responseResult: Result[GetParameterResponse, AwsSecrets.SecretsError] = try {
    val client = getSsmClient()
    val request = newGetParameterRequest()
    setParameterName(request, path)
    setWithDecryption(request, decrypt)
    Ok(value = await getParameterAsyncExtern(client, request, noCancellation()))
  } catch Bug as b {
    Err(error = classifyParameterError(path, b.message))
  }

  val result: Result[String, AwsSecrets.SecretsError] = match responseResult {
    case Err(e) -> Err(error = e)
    case Ok(response) -> Ok(
      value = parameterValueOf(
        parameterOf(response)
      )
    )
  }

  if ttlSeconds > 0 {
    match result {
      case Ok(v) -> cdPut(
        parameterCache,
        cacheKey,
        CacheEntry(value = v, expiresAtMs = Std.Time.nowEpochMillis() + ttlSeconds.toLong() * 1000i64)
      )
      case Err(_) -> ()
    }
  }

  result
}
