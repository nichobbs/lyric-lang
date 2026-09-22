//! tests/secrets_tests.l — tests for the pure-Lyric surface of lyric-aws-secrets.
//!
//! Covers SecretsError union construction and errorMessage formatting (no
//! feature flag required), plus init()/getSecret()/getSecretField()/
//! getParameter()/getParameterRaw() against the local no-op kernel
//! (`--features local` — see the "Local kernel" section below), and the
//! jvm kernel's error-classification logic (`--features jvm` — see the
//! "JVM kernel" section). This file compiles under all three
//! `AwsSecrets.Kernel.Net` features (issue #5411), so per-feature checks
//! route through a `@cfg`-gated helper function with one variant per
//! feature (mirroring `lyric-jobs/tests/jobs_tests.l`'s
//! `quartzE2EScenario` idiom) rather than gating the `test` block itself
//! — a bare `test` block with its own `@cfg` has been observed to compile
//! into an invalid MSIL program (see that file's header note).
//!
//! Both the AWS SDK (.NET) and JVM backends now bind real
//! `AmazonSecretsManagerClient`/`SecretsManagerClient` (and SSM equivalent)
//! calls (issue #6864, `secrets_kernel_aws.l`/`secrets_kernel_jvm.l`'s
//! headers) — no live or mocked AWS endpoint is set up in this suite, so
//! `getSecret`/`getParameter` are only checked to fail as a typed `Err`
//! (never a silent `Ok`, never an unhandled exception) rather than
//! succeed. Both kernels' pure-Lyric error classification, JSON-field
//! extraction, and cache-key logic are covered directly.
@test_module
package AwsSecrets.SecretsTests

import Std.Core
import Std.Testing
import AwsSecrets
import AwsSecrets.Kernel.Net as SecretsKernel

// ─── SecretsError union ───────────────────────────────────────────────────────
test "SecretsError.NotFound: carries secret name" {
  val e = NotFound(name = "my-service/prod")
  match e {
    case NotFound(n) -> assertEqual(n, "my-service/prod", "secret name")
    case _ -> assertTrue(false, "expected NotFound")
  }
}

test "SecretsError.AccessDenied: carries name and message" {
  val e = AccessDenied(name = "my-secret", message = "not authorized")
  match e {
    case AccessDenied(n, m) -> {
      assertEqual(n, "my-secret", "name field")
      assertEqual(m, "not authorized", "message field")
    }
    case _ -> assertTrue(false, "expected AccessDenied")
  }
}

test "SecretsError.DecryptionError: carries name and message" {
  val e = DecryptionError(name = "/my/param", message = "KMS key not found")
  match e {
    case DecryptionError(n, m) -> {
      assertEqual(n, "/my/param", "name field")
      assertEqual(m, "KMS key not found", "message field")
    }
    case _ -> assertTrue(false, "expected DecryptionError")
  }
}

test "SecretsError.ParseError: carries name, key, and message" {
  val e = ParseError(name = "my-json-secret", key = "dbPassword", message = "key absent")
  match e {
    case ParseError(n, k, m) -> {
      assertEqual(n, "my-json-secret", "name field")
      assertEqual(k, "dbPassword", "key field")
      assertEqual(m, "key absent", "message field")
    }
    case _ -> assertTrue(false, "expected ParseError")
  }
}

test "SecretsError.BinaryValueUnsupported: carries secret name" {
  val e = BinaryValueUnsupported(name = "my-binary-secret")
  match e {
    case BinaryValueUnsupported(n) -> assertEqual(n, "my-binary-secret", "secret name")
    case _ -> assertTrue(false, "expected BinaryValueUnsupported")
  }
}

// ─── errorMessage ─────────────────────────────────────────────────────────────
test "errorMessage: NotFound includes secret name" {
  val e = NotFound(name = "app/prod/jwt-secret")
  val msg = AwsSecrets.errorMessage(e)
  assertTrue(msg.contains("app/prod/jwt-secret"), "error message must include the secret name")
  assertTrue(msg.length > 0, "error message must be non-empty")
}

test "errorMessage: AccessDenied includes name and inner message" {
  val e = AccessDenied(name = "my-secret", message = "iam:GetSecretValue denied")
  val msg = AwsSecrets.errorMessage(e)
  assertTrue(msg.contains("my-secret"), "message includes secret name")
  assertTrue(msg.contains("iam:GetSecretValue denied"), "message includes inner error")
}

test "errorMessage: DecryptionError includes name" {
  val e = DecryptionError(name = "/secure/key", message = "KMS unavailable")
  val msg = AwsSecrets.errorMessage(e)
  assertTrue(msg.contains("/secure/key"), "message includes parameter name")
}

test "errorMessage: ParseError includes both name and key" {
  val e = ParseError(name = "structured-secret", key = "missingField", message = "key absent")
  val msg = AwsSecrets.errorMessage(e)
  assertTrue(msg.contains("structured-secret"), "message includes secret name")
  assertTrue(msg.contains("missingField"), "message includes missing key")
}

test "errorMessage: BinaryValueUnsupported includes secret name" {
  val e = BinaryValueUnsupported(name = "my-binary-secret")
  val msg = AwsSecrets.errorMessage(e)
  assertTrue(msg.contains("my-binary-secret"), "message includes secret name")
  assertTrue(msg.length > 0, "error message must be non-empty")
}

// ─── Local kernel (feature = "local") ──────────────────────────────────────────
// These exercise AwsSecrets.Kernel.Net's local no-op backend: init() always
// succeeds (annotation scanning is a no-op; env var overrides are checked
// later, at config-field read time), and every fetch call always returns
// NotFound (there is no AWS SDK in local mode — set the corresponding env var
// instead). The `aws`/`jvm` variants below are not applicable to this
// backend's specific no-op contract, so they skip with a trivial "OK" —
// see the JVM kernel section further down for what actually is covered
// under `--features jvm`.
@cfg(feature = "local")
func localModeInitScenario(): String {
  match AwsSecrets.init() {
    case Ok(_) -> "OK"
    case Err(e) -> "init() must return Ok in local mode: " + AwsSecrets.errorMessage(e)
  }
}

@cfg(feature = "aws")
func localModeInitScenario(): String {
  "OK" // local-mode-specific contract; not applicable under aws
}

@cfg(feature = "jvm")
func localModeInitScenario(): String {
  "OK" // local-mode-specific contract; not applicable under jvm
}

test "init(): always succeeds in local mode" {
  assertEqual(localModeInitScenario(), "OK", "init() must return Ok in local mode")
}

@cfg(feature = "local")
func localModeGetSecretScenario(): String {
  match AwsSecrets.getSecret("my-service/prod") {
    case Ok(_) -> "getSecret() must return Err in local mode"
    case Err(e) -> match e {
      case NotFound(n) -> if n == "my-service/prod" {
        "OK"
      } else {
        "NotFound carried the wrong secret name: " + n
      }
      case _ -> "expected NotFound"
    }
  }
}

@cfg(feature = "aws")
func localModeGetSecretScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func localModeGetSecretScenario(): String {
  "OK"
}

test "getSecret(): always returns NotFound in local mode" {
  assertEqual(localModeGetSecretScenario(), "OK", "getSecret() must return NotFound(name) in local mode")
}

@cfg(feature = "local")
func localModeGetSecretFieldScenario(): String {
  match AwsSecrets.getSecretField("my-service/prod", "dbPassword") {
    case Ok(_) -> "getSecretField() must return Err in local mode"
    case Err(e) -> match e {
      case NotFound(n) -> if n == "my-service/prod" {
        "OK"
      } else {
        "NotFound carried the wrong secret name: " + n
      }
      case _ -> "expected NotFound"
    }
  }
}

@cfg(feature = "aws")
func localModeGetSecretFieldScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func localModeGetSecretFieldScenario(): String {
  "OK"
}

test "getSecretField(): always returns NotFound in local mode" {
  assertEqual(localModeGetSecretFieldScenario(), "OK", "getSecretField() must return NotFound(name) in local mode")
}

@cfg(feature = "local")
func localModeGetParameterScenario(): String {
  match AwsSecrets.getParameter("/my-service/signing-key") {
    case Ok(_) -> "getParameter() must return Err in local mode"
    case Err(e) -> match e {
      case NotFound(n) -> if n == "/my-service/signing-key" {
        "OK"
      } else {
        "NotFound carried the wrong parameter path: " + n
      }
      case _ -> "expected NotFound"
    }
  }
}

@cfg(feature = "aws")
func localModeGetParameterScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func localModeGetParameterScenario(): String {
  "OK"
}

test "getParameter(): always returns NotFound in local mode" {
  assertEqual(localModeGetParameterScenario(), "OK", "getParameter() must return NotFound(name) in local mode")
}

@cfg(feature = "local")
func localModeGetParameterRawScenario(): String {
  match AwsSecrets.getParameterRaw("/my-service/plain-param") {
    case Ok(_) -> "getParameterRaw() must return Err in local mode"
    case Err(e) -> match e {
      case NotFound(n) -> if n == "/my-service/plain-param" {
        "OK"
      } else {
        "NotFound carried the wrong parameter path: " + n
      }
      case _ -> "expected NotFound"
    }
  }
}

@cfg(feature = "aws")
func localModeGetParameterRawScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func localModeGetParameterRawScenario(): String {
  "OK"
}

test "getParameterRaw(): always returns NotFound in local mode" {
  assertEqual(localModeGetParameterRawScenario(), "OK", "getParameterRaw() must return NotFound(name) in local mode")
}

// ─── JVM kernel (feature = "jvm") ──────────────────────────────────────────────
// `secrets_kernel_jvm.l` binds real `SecretsManagerClient`/`SsmClient`
// calls (issue #5411) — covered here is the part reachable without a live
// or mocked AWS endpoint: `classifySecretsError`/`classifyParameterError`,
// the best-effort message-substring classification the kernel's header
// documents as a known limitation (no typed-exception-hierarchy pattern
// match across the FFI `catch Bug` boundary). The real client/request/
// response calls are exercised by compiling this whole suite under
// `--target jvm --features jvm` (real AWS SDK metadata resolution — this
// fails loudly if any binding is wrong) but not by a runtime assertion in
// this PR; see that file's header for what remains unverified against a
// live/mocked AWS endpoint.
@cfg(feature = "jvm")
func jvmClassifySecretsErrorScenario(): String {
  val notFound = SecretsKernel.classifySecretsError("my-secret", "Secrets Manager can't find the specified secret.")
  val accessDenied = SecretsKernel.classifySecretsError(
    "my-secret",
    "User is not authorized to perform: secretsmanager:GetSecretValue"
  )
  val decryption = SecretsKernel.classifySecretsError(
    "my-secret",
    "DecryptionFailureException: Secrets Manager can't decrypt the protected secret text"
  )
  val unknown = SecretsKernel.classifySecretsError("my-secret", "Connection refused")
  match notFound {
    case NotFound(n) -> if n != "my-secret" { return "NotFound carried the wrong name: " + n } else { () }
    case _ -> return "expected NotFound classification for 'can't find the specified secret'"
  }
  match accessDenied {
    case AccessDenied(n, _) -> if n != "my-secret" { return "AccessDenied carried the wrong name: " + n } else { () }
    case _ -> return "expected AccessDenied classification for 'not authorized'"
  }
  match decryption {
    case DecryptionError(n, _) -> if n != "my-secret" {
      return "DecryptionError carried the wrong name: " + n
    } else {
      ()
    }
    case _ -> return "expected DecryptionError classification for 'DecryptionFailureException'"
  }
  match unknown {
    case NetworkError(n, m) -> if n == "my-secret" and m == "Connection refused" {
      "OK"
    } else {
      "NetworkError carried the wrong fields"
    }
    case _ -> "expected NetworkError fallback classification for an unrecognised message"
  }
}

@cfg(feature = "local")
func jvmClassifySecretsErrorScenario(): String {
  "OK"
}

@cfg(feature = "aws")
func jvmClassifySecretsErrorScenario(): String {
  "OK"
}

test "jvm kernel: classifySecretsError maps known AWS error messages to typed SecretsError variants" {
  assertEqual(
    jvmClassifySecretsErrorScenario(),
    "OK",
    "classifySecretsError must classify NotFound/AccessDenied/DecryptionError and fall back to NetworkError"
  )
}

@cfg(feature = "jvm")
func jvmClassifyParameterErrorScenario(): String {
  val notFound = SecretsKernel.classifyParameterError("/my/param", "ParameterNotFound: /my/param")
  val accessDenied = SecretsKernel.classifyParameterError(
    "/my/param",
    "User is not authorized to perform: ssm:GetParameter"
  )
  val decryption = SecretsKernel.classifyParameterError("/my/param", "InvalidKeyId: the KMS key is disabled")
  val unknown = SecretsKernel.classifyParameterError("/my/param", "Request timed out")
  match notFound {
    case NotFound(n) -> if n != "/my/param" { return "NotFound carried the wrong name: " + n } else { () }
    case _ -> return "expected NotFound classification for 'ParameterNotFound'"
  }
  match accessDenied {
    case AccessDenied(n, _) -> if n != "/my/param" { return "AccessDenied carried the wrong name: " + n } else { () }
    case _ -> return "expected AccessDenied classification for 'not authorized'"
  }
  match decryption {
    case DecryptionError(n, _) -> if n != "/my/param" {
      return "DecryptionError carried the wrong name: " + n
    } else {
      ()
    }
    case _ -> return "expected DecryptionError classification for 'InvalidKeyId'"
  }
  match unknown {
    case NetworkError(n, m) -> if n == "/my/param" and m == "Request timed out" {
      "OK"
    } else {
      "NetworkError carried the wrong fields"
    }
    case _ -> "expected NetworkError fallback classification for an unrecognised message"
  }
}

@cfg(feature = "local")
func jvmClassifyParameterErrorScenario(): String {
  "OK"
}

@cfg(feature = "aws")
func jvmClassifyParameterErrorScenario(): String {
  "OK"
}

test "jvm kernel: classifyParameterError maps known AWS error messages to typed SecretsError variants" {
  assertEqual(
    jvmClassifyParameterErrorScenario(),
    "OK",
    "classifyParameterError must classify NotFound/AccessDenied/DecryptionError and fall back to NetworkError"
  )
}

// ─── AWS (.NET) kernel (feature = "aws") ───────────────────────────────────────
// `secrets_kernel_aws.l` binds real `AmazonSecretsManagerClient`/
// `AmazonSimpleSystemsManagementClient` calls (issue #6864) — covered here
// is the part reachable without a live AWS endpoint/credentials:
// `init()`'s `initFromAnnotations()` stays NOT_IMPLEMENTED (a separate,
// genuine compiler gap, #6866, unrelated to #6864's async-API-shape
// question this file otherwise resolves), and `getSecret()`/
// `getParameter()` now genuinely attempt a real SDK call and correctly
// surface a non-NOT_IMPLEMENTED, typed error when no region/credentials
// are configured (this sandbox's environment) rather than the old
// unconditional NOT_IMPLEMENTED stub. The real client/request/response
// wiring is exercised by compiling and running this whole suite under
// `--target dotnet --no-default-features --features aws` (a genuine
// AWSSDK.SecretsManager/AWSSDK.SimpleSystemsManagement metadata
// resolution — this fails loudly if any binding is wrong); the pure
// classification/extraction/cache-key logic below covers what's testable
// without a live/mocked AWS endpoint, mirroring the jvm kernel's own test
// sections exactly.
@cfg(feature = "aws")
func awsInitStillNotImplementedScenario(): String {
  match AwsSecrets.init() {
    case Ok(_) -> "init() must not silently succeed on the aws feature: initFromAnnotations() stays NOT_IMPLEMENTED (issue #6866)"
    case Err(e) -> if AwsSecrets.errorMessage(e).contains("is not implemented") {
      "OK"
    } else {
      "init()'s error must say it is not implemented, got: " + AwsSecrets.errorMessage(e)
    }
  }
}

@cfg(feature = "local")
func awsInitStillNotImplementedScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func awsInitStillNotImplementedScenario(): String {
  "OK"
}

test "aws kernel: init() still returns NOT_IMPLEMENTED (initFromAnnotations, issue #6866, unaffected by #6864)" {
  assertEqual(
    awsInitStillNotImplementedScenario(),
    "OK",
    "initFromAnnotations() must stay NOT_IMPLEMENTED regardless of #6864's fetchSecret/fetchParameter fix"
  )
}

// getSecret()/getParameter() now make a real SDK call. Without a live AWS
// endpoint or credentials, the client construction or the call itself
// fails, but MUST come back as a typed Err (never a silent Ok, never an
// unhandled exception reaching the caller) — the exact failure this
// sandbox surfaces is "No RegionEndpoint or ServiceURL configured",
// correctly falling back to NetworkError via classifySecretsError's
// documented best-effort classification.
@cfg(feature = "aws")
func awsRealCallNeverPanicsScenario(): String {
  match AwsSecrets.getSecret("my-service/prod") {
    case Ok(_) -> return "getSecret() unexpectedly succeeded with no AWS credentials/region configured"
    case Err(_) -> ()
  }
  match AwsSecrets.getParameter("/my-service/signing-key") {
    case Ok(_) -> "getParameter() unexpectedly succeeded with no AWS credentials/region configured"
    case Err(_) -> "OK"
  }
}

@cfg(feature = "local")
func awsRealCallNeverPanicsScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func awsRealCallNeverPanicsScenario(): String {
  "OK"
}

test "aws kernel: getSecret/getParameter never panic uncaught without AWS credentials, always a typed Err" {
  assertEqual(
    awsRealCallNeverPanicsScenario(),
    "OK",
    "a real SDK call failure (client construction or the network call itself) must always surface as a typed SecretsError"
  )
}

// ─── classifySecretsError / classifyParameterError (aws kernel) ───────────────
// Pure message-substring classification, independent of any network/client
// call — identical structure to the jvm kernel's own coverage above.
@cfg(feature = "aws")
func netClassifySecretsErrorScenario(): String {
  val notFound = SecretsKernel.classifySecretsError("my-secret", "Secrets Manager can't find the specified secret.")
  val accessDenied = SecretsKernel.classifySecretsError(
    "my-secret",
    "User is not authorized to perform: secretsmanager:GetSecretValue"
  )
  val decryption = SecretsKernel.classifySecretsError(
    "my-secret",
    "DecryptionFailureException: Secrets Manager can't decrypt the protected secret text"
  )
  val unknown = SecretsKernel.classifySecretsError("my-secret", "Connection refused")
  match notFound {
    case NotFound(n) -> if n != "my-secret" { return "NotFound carried the wrong name: " + n } else { () }
    case _ -> return "expected NotFound classification for 'can't find the specified secret'"
  }
  match accessDenied {
    case AccessDenied(n, _) -> if n != "my-secret" { return "AccessDenied carried the wrong name: " + n } else { () }
    case _ -> return "expected AccessDenied classification for 'not authorized'"
  }
  match decryption {
    case DecryptionError(n, _) -> if n != "my-secret" {
      return "DecryptionError carried the wrong name: " + n
    } else {
      ()
    }
    case _ -> return "expected DecryptionError classification for 'DecryptionFailureException'"
  }
  match unknown {
    case NetworkError(n, m) -> if n == "my-secret" and m == "Connection refused" {
      "OK"
    } else {
      "NetworkError carried the wrong fields"
    }
    case _ -> "expected NetworkError fallback classification for an unrecognised message"
  }
}

@cfg(feature = "local")
func netClassifySecretsErrorScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func netClassifySecretsErrorScenario(): String {
  "OK"
}

test "aws kernel: classifySecretsError maps known AWS error messages to typed SecretsError variants" {
  assertEqual(
    netClassifySecretsErrorScenario(),
    "OK",
    "classifySecretsError must classify NotFound/AccessDenied/DecryptionError and fall back to NetworkError"
  )
}

@cfg(feature = "aws")
func netClassifyParameterErrorScenario(): String {
  val notFound = SecretsKernel.classifyParameterError("/my/param", "ParameterNotFound: /my/param")
  val accessDenied = SecretsKernel.classifyParameterError(
    "/my/param",
    "User is not authorized to perform: ssm:GetParameter"
  )
  val decryption = SecretsKernel.classifyParameterError("/my/param", "InvalidKeyId: the KMS key is disabled")
  val unknown = SecretsKernel.classifyParameterError("/my/param", "Request timed out")
  match notFound {
    case NotFound(n) -> if n != "/my/param" { return "NotFound carried the wrong name: " + n } else { () }
    case _ -> return "expected NotFound classification for 'ParameterNotFound'"
  }
  match accessDenied {
    case AccessDenied(n, _) -> if n != "/my/param" { return "AccessDenied carried the wrong name: " + n } else { () }
    case _ -> return "expected AccessDenied classification for 'not authorized'"
  }
  match decryption {
    case DecryptionError(n, _) -> if n != "/my/param" {
      return "DecryptionError carried the wrong name: " + n
    } else {
      ()
    }
    case _ -> return "expected DecryptionError classification for 'InvalidKeyId'"
  }
  match unknown {
    case NetworkError(n, m) -> if n == "/my/param" and m == "Request timed out" {
      "OK"
    } else {
      "NetworkError carried the wrong fields"
    }
    case _ -> "expected NetworkError fallback classification for an unrecognised message"
  }
}

@cfg(feature = "local")
func netClassifyParameterErrorScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func netClassifyParameterErrorScenario(): String {
  "OK"
}

test "aws kernel: classifyParameterError maps known AWS error messages to typed SecretsError variants" {
  assertEqual(
    netClassifyParameterErrorScenario(),
    "OK",
    "classifyParameterError must classify NotFound/AccessDenied/DecryptionError and fall back to NetworkError"
  )
}

// ─── extractSecretField / extractSecretValue (aws kernel) ─────────────────────
// Pure JSON-field-extraction and binary-vs-string dispatch logic,
// independent of any network/client call — identical structure to the jvm
// kernel's own coverage above (both kernels carry their own copy of this
// logic, matching the established per-feature-kernel duplication idiom).
@cfg(feature = "aws")
func netExtractSecretFieldScenario(): String {
  val noKey = SecretsKernel.extractSecretField("my-secret", None, "raw-string-value")
  match noKey {
    case Ok(v) -> if v != "raw-string-value" {
      return "key=None must return the raw secret string unchanged"
    } else {
      ()
    }
    case Err(_) -> return "key=None must never fail"
  }

  val stringField = SecretsKernel.extractSecretField(
    "my-secret",
    Some("dbPassword"),
    "{\"dbPassword\": \"hunter2\", \"dbPort\": 5432}"
  )
  match stringField {
    case Ok(v) -> if v != "hunter2" { return "expected the dbPassword field's value, got: " + v } else { () }
    case Err(e) -> return "expected Ok for a string field, got Err: " + AwsSecrets.errorMessage(e)
  }

  val nonStringField = SecretsKernel.extractSecretField(
    "my-secret",
    Some("dbPort"),
    "{\"dbPassword\": \"hunter2\", \"dbPort\": 5432}"
  )
  match nonStringField {
    case Ok(v) -> return "expected ParseError for a non-string field, got Ok: " + v
    case Err(ParseError(n, k, _)) -> if n != "my-secret" or k != "dbPort" {
      return "ParseError carried the wrong name/key"
    } else {
      ()
    }
    case Err(e) -> return "expected ParseError for a non-string field, got a different error: " + AwsSecrets.errorMessage(e)
  }

  val malformedJson = SecretsKernel.extractSecretField("my-secret", Some("dbPassword"), "{not valid json")
  match malformedJson {
    case Ok(v) -> return "expected ParseError for malformed JSON, got Ok: " + v
    case Err(ParseError(n, k, _)) -> if n != "my-secret" or k != "dbPassword" {
      return "ParseError carried the wrong name/key for malformed JSON"
    } else {
      ()
    }
    case Err(e) -> return "expected ParseError for malformed JSON, got a different error: " + AwsSecrets.errorMessage(e)
  }

  val missingField = SecretsKernel.extractSecretField("my-secret", Some("missing"), "{\"dbPassword\": \"hunter2\"}")
  match missingField {
    case Ok(v) -> "expected ParseError for a missing field, got Ok: " + v
    case Err(ParseError(_, _, _)) -> "OK"
    case Err(e) -> "expected ParseError for a missing field, got a different error: " + AwsSecrets.errorMessage(e)
  }
}

@cfg(feature = "local")
func netExtractSecretFieldScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func netExtractSecretFieldScenario(): String {
  "OK"
}

test "aws kernel: extractSecretField returns ParseError (never panics) for a non-string or missing JSON field" {
  assertEqual(
    netExtractSecretFieldScenario(),
    "OK",
    "extractSecretField must convert a Std.Json.getString panic on a non-string field into a typed ParseError"
  )
}

@cfg(feature = "aws")
func netExtractSecretValueScenario(): String {
  val noneKeyBinary = SecretsKernel.extractSecretValue("my-binary-secret", None, None)
  match noneKeyBinary {
    case Ok(v) -> return "expected BinaryValueUnsupported for a binary secret, got Ok: " + v
    case Err(BinaryValueUnsupported(n)) -> if n != "my-binary-secret" {
      return "BinaryValueUnsupported carried the wrong name: " + n
    } else {
      ()
    }
    case Err(e) -> return "expected BinaryValueUnsupported, got a different error: " + AwsSecrets.errorMessage(e)
  }

  val someKeyBinary = SecretsKernel.extractSecretValue("my-binary-secret", Some("field"), None)
  match someKeyBinary {
    case Ok(v) -> return "expected BinaryValueUnsupported for a binary secret with a key, got Ok: " + v
    case Err(BinaryValueUnsupported(_)) -> ()
    case Err(e) -> return "expected BinaryValueUnsupported, got a different error: " + AwsSecrets.errorMessage(e)
  }

  val stringSecret = SecretsKernel.extractSecretValue("my-secret", None, Some("plain-value"))
  match stringSecret {
    case Ok(v) -> if v != "plain-value" { "expected the raw secret string, got: " + v } else { "OK" }
    case Err(e) -> "expected Ok for a string secret, got Err: " + AwsSecrets.errorMessage(e)
  }
}

@cfg(feature = "local")
func netExtractSecretValueScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func netExtractSecretValueScenario(): String {
  "OK"
}

test "aws kernel: extractSecretValue converts a binary (null SecretString) secret into BinaryValueUnsupported, never Ok(null)" {
  assertEqual(
    netExtractSecretValueScenario(),
    "OK",
    "extractSecretValue must convert a null .NET SecretString into a typed BinaryValueUnsupported"
  )
}

// ─── secretCacheKeyFor / parameterCacheKeyFor (aws kernel) ────────────────────
// Pure cache-key-construction logic, independent of any network/client
// call — identical collision-safety coverage to the jvm kernel's own
// #7046 regression above.
@cfg(feature = "aws")
func netCacheKeyCollisionScenario(): String {
  val noneKey = SecretsKernel.secretCacheKeyFor("foo bar", None)
  val someKey = SecretsKernel.secretCacheKeyFor("foo", Some("bar"))
  if noneKey == someKey {
    return "getSecret(\"foo bar\") and getSecretField(\"foo\", \"bar\") must not share a cache key, both produced: " +
      noneKey
  }

  val split1 = SecretsKernel.secretCacheKeyFor("ab", Some("cd"))
  val split2 = SecretsKernel.secretCacheKeyFor("abc", Some("d"))
  if split1 == split2 {
    return "differently-split (name, key) pairs must not share a cache key, both produced: " + split1
  }

  if SecretsKernel.secretCacheKeyFor("my-secret", Some("field")) != SecretsKernel.secretCacheKeyFor("my-secret", Some("field")) {
    return "identical (name, key) pairs must produce identical cache keys"
  }
  if SecretsKernel.secretCacheKeyFor("my-secret", None) != SecretsKernel.secretCacheKeyFor("my-secret", None) {
    return "identical (name, None) pairs must produce identical cache keys"
  }

  val plainSecret = SecretsKernel.secretCacheKeyFor("my-secret", None)
  val fieldOfSameName = SecretsKernel.secretCacheKeyFor("my-secret", Some(""))
  if plainSecret == fieldOfSameName {
    return "a None-keyed and a Some-keyed cache entry must never collide, both produced: " + plainSecret
  }

  val paramKey1 = SecretsKernel.parameterCacheKeyFor("my-param", true)
  val paramKey2 = SecretsKernel.parameterCacheKeyFor("my-param", false)
  if paramKey1 == paramKey2 {
    return "different decrypt flags must not share a parameter cache key, both produced: " + paramKey1
  }
  if SecretsKernel.parameterCacheKeyFor("/app/db/password", true) != SecretsKernel.parameterCacheKeyFor("/app/db/password", true) {
    return "identical (path, decrypt) pairs must produce identical parameter cache keys"
  }

  "OK"
}

@cfg(feature = "local")
func netCacheKeyCollisionScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func netCacheKeyCollisionScenario(): String {
  "OK"
}

test "aws kernel: secretCacheKeyFor/parameterCacheKeyFor never collide across differently-split inputs" {
  assertEqual(
    netCacheKeyCollisionScenario(),
    "OK",
    "a wrong-secret-returned cache-key collision must be impossible regardless of what characters name/key/path contain"
  )
}

// ─── extractSecretField (jvm kernel) ───────────────────────────────────────
// Pure JSON-field-extraction logic, independent of any network/client call
// — exercises the panic-vs-Err fix for a non-string field value without
// needing a live or mocked AWS endpoint.
@cfg(feature = "jvm")
func jvmExtractSecretFieldScenario(): String {
  val noKey = SecretsKernel.extractSecretField("my-secret", None, "raw-string-value")
  match noKey {
    case Ok(v) -> if v != "raw-string-value" {
      return "key=None must return the raw secret string unchanged"
    } else {
      ()
    }
    case Err(_) -> return "key=None must never fail"
  }

  val stringField = SecretsKernel.extractSecretField(
    "my-secret",
    Some("dbPassword"),
    "{\"dbPassword\": \"hunter2\", \"dbPort\": 5432}"
  )
  match stringField {
    case Ok(v) -> if v != "hunter2" { return "expected the dbPassword field's value, got: " + v } else { () }
    case Err(e) -> return "expected Ok for a string field, got Err: " + AwsSecrets.errorMessage(e)
  }

  // The failure scenario from the review finding: a non-string field (an
  // ordinary shape — AWS's own RDS-generated secrets include numeric
  // fields like this) must return a typed ParseError, never panic.
  val nonStringField = SecretsKernel.extractSecretField(
    "my-secret",
    Some("dbPort"),
    "{\"dbPassword\": \"hunter2\", \"dbPort\": 5432}"
  )
  match nonStringField {
    case Ok(v) -> return "expected ParseError for a non-string field, got Ok: " + v
    case Err(ParseError(n, k, _)) -> if n != "my-secret" or k != "dbPort" {
      return "ParseError carried the wrong name/key"
    } else {
      ()
    }
    case Err(e) -> return "expected ParseError for a non-string field, got a different error: " + AwsSecrets.errorMessage(e)
  }

  // Malformed JSON entirely (Std.Json.tryParseJson's own Err branch) must
  // also come back as a typed ParseError, not propagate a raw parse-error
  // string or panic.
  val malformedJson = SecretsKernel.extractSecretField("my-secret", Some("dbPassword"), "{not valid json")
  match malformedJson {
    case Ok(v) -> return "expected ParseError for malformed JSON, got Ok: " + v
    case Err(ParseError(n, k, _)) -> if n != "my-secret" or k != "dbPassword" {
      return "ParseError carried the wrong name/key for malformed JSON"
    } else {
      ()
    }
    case Err(e) -> return "expected ParseError for malformed JSON, got a different error: " + AwsSecrets.errorMessage(e)
  }

  val missingField = SecretsKernel.extractSecretField("my-secret", Some("missing"), "{\"dbPassword\": \"hunter2\"}")
  match missingField {
    case Ok(v) -> "expected ParseError for a missing field, got Ok: " + v
    case Err(ParseError(_, _, _)) -> "OK"
    case Err(e) -> "expected ParseError for a missing field, got a different error: " + AwsSecrets.errorMessage(e)
  }
}

@cfg(feature = "local")
func jvmExtractSecretFieldScenario(): String {
  "OK"
}

@cfg(feature = "aws")
func jvmExtractSecretFieldScenario(): String {
  "OK"
}

test "jvm kernel: extractSecretField returns ParseError (never panics) for a non-string or missing JSON field" {
  assertEqual(
    jvmExtractSecretFieldScenario(),
    "OK",
    "extractSecretField must convert a Std.Json.getString panic on a non-string field into a typed ParseError"
  )
}

// ─── secretCacheKeyFor / parameterCacheKeyFor (jvm kernel) ─────────────────
// Pure cache-key-construction logic, independent of any network/client call
// — regression coverage for the wrong-secret-returned collision bug (#7046):
// a plain `name + " " + k` join let getSecret("foo bar") (key=None) and
// getSecretField("foo", "bar") (name="foo", key=Some("bar")) both hash to
// "foo bar", so a call for one could be served the other's cached secret.
@cfg(feature = "jvm")
func jvmCacheKeyCollisionScenario(): String {
  // The exact review-finding collision: getSecret("foo bar") vs.
  // getSecretField("foo", "bar") must no longer produce the same key.
  val noneKey = SecretsKernel.secretCacheKeyFor("foo bar", None)
  val someKey = SecretsKernel.secretCacheKeyFor("foo", Some("bar"))
  if noneKey == someKey {
    return "getSecret(\"foo bar\") and getSecretField(\"foo\", \"bar\") must not share a cache key, both produced: " +
      noneKey
  }

  // The general form of the same bug: any (name, key) split that reassembles
  // to the same characters must still be distinguished — a naive separator
  // join can't tell "ab"/Some("cd") apart from "abc"/Some("d") once the
  // parts are concatenated ("ab:cd" vs "abc:d" collide under any single
  // fixed delimiter that could also appear inside `name`).
  val split1 = SecretsKernel.secretCacheKeyFor("ab", Some("cd"))
  val split2 = SecretsKernel.secretCacheKeyFor("abc", Some("d"))
  if split1 == split2 {
    return "differently-split (name, key) pairs must not share a cache key, both produced: " + split1
  }

  // Same name+key must still hit the cache (the fix must not break the
  // happy path it's supposed to preserve).
  if SecretsKernel.secretCacheKeyFor("my-secret", Some("field")) != SecretsKernel.secretCacheKeyFor("my-secret", Some("field")) {
    return "identical (name, key) pairs must produce identical cache keys"
  }
  if SecretsKernel.secretCacheKeyFor("my-secret", None) != SecretsKernel.secretCacheKeyFor("my-secret", None) {
    return "identical (name, None) pairs must produce identical cache keys"
  }

  // A None-keyed secret must never collide with any Some-keyed one, even
  // when the Some name/key are chosen to try to reconstruct the None name.
  val plainSecret = SecretsKernel.secretCacheKeyFor("my-secret", None)
  val fieldOfSameName = SecretsKernel.secretCacheKeyFor("my-secret", Some(""))
  if plainSecret == fieldOfSameName {
    return "a None-keyed and a Some-keyed cache entry must never collide, both produced: " + plainSecret
  }

  // parameterCacheKeyFor must distinguish differently-split (path, decrypt)
  // pairs the same way.
  val paramKey1 = SecretsKernel.parameterCacheKeyFor("my-param", true)
  val paramKey2 = SecretsKernel.parameterCacheKeyFor("my-param", false)
  if paramKey1 == paramKey2 {
    return "different decrypt flags must not share a parameter cache key, both produced: " + paramKey1
  }
  if SecretsKernel.parameterCacheKeyFor("/app/db/password", true) != SecretsKernel.parameterCacheKeyFor("/app/db/password", true) {
    return "identical (path, decrypt) pairs must produce identical parameter cache keys"
  }

  "OK"
}

@cfg(feature = "local")
func jvmCacheKeyCollisionScenario(): String {
  "OK"
}

@cfg(feature = "aws")
func jvmCacheKeyCollisionScenario(): String {
  "OK"
}

test "jvm kernel: secretCacheKeyFor/parameterCacheKeyFor never collide across differently-split inputs (#7046)" {
  assertEqual(
    jvmCacheKeyCollisionScenario(),
    "OK",
    "a wrong-secret-returned cache-key collision must be impossible regardless of what characters name/key/path contain"
  )
}

// ─── extractSecretValue (jvm kernel) ────────────────────────────────────────
// Pure binary-vs-string secret dispatch, independent of any network/client
// call — regression coverage for the silent-Ok(null) bug (#7047): a binary
// (SecretBinary) secret has no SecretString, so response.secretString()
// returns Java null; that null must become a typed BinaryValueUnsupported
// error, never an Ok(value = null) or an uncaught panic.
@cfg(feature = "jvm")
func jvmExtractSecretValueScenario(): String {
  // The review-finding case: no secretString at all (binary secret),
  // key = None (raw fetch) — must be a typed error, never Ok(null).
  val noneKeyBinary = SecretsKernel.extractSecretValue("my-binary-secret", None, None)
  match noneKeyBinary {
    case Ok(v) -> return "a binary secret (key=None) must never return Ok, got Ok: " + v
    case Err(BinaryValueUnsupported(n)) -> if n != "my-binary-secret" {
      return "BinaryValueUnsupported carried the wrong secret name: " + n
    } else {
      ()
    }
    case Err(e) -> return "a binary secret (key=None) must return BinaryValueUnsupported, got a different error: " +
      AwsSecrets.errorMessage(e)
  }

  // Same for the key=Some path — must not attempt JSON-parsing a null and
  // must not panic.
  val someKeyBinary = SecretsKernel.extractSecretValue("my-binary-secret", Some("field"), None)
  match someKeyBinary {
    case Ok(v) -> return "a binary secret (key=Some) must never return Ok, got Ok: " + v
    case Err(BinaryValueUnsupported(n)) -> if n != "my-binary-secret" {
      return "BinaryValueUnsupported carried the wrong secret name: " + n
    } else {
      ()
    }
    case Err(e) -> return "a binary secret (key=Some) must return BinaryValueUnsupported, got a different error: " +
      AwsSecrets.errorMessage(e)
  }

  // A real (non-null) string secret must still flow through to
  // extractSecretField normally — the fix must not break the happy path.
  val realString = SecretsKernel.extractSecretValue("my-secret", None, Some("raw-string-value"))
  match realString {
    case Ok(v) -> if v != "raw-string-value" {
      return "a string secret must pass through unchanged, got: " + v
    } else {
      ()
    }
    case Err(e) -> return "a string secret must never fail, got Err: " + AwsSecrets.errorMessage(e)
  }

  "OK"
}

@cfg(feature = "local")
func jvmExtractSecretValueScenario(): String {
  "OK"
}

@cfg(feature = "aws")
func jvmExtractSecretValueScenario(): String {
  "OK"
}

test "jvm kernel: extractSecretValue converts a binary (null SecretString) secret into BinaryValueUnsupported, never Ok(null) (#7047)" {
  assertEqual(
    jvmExtractSecretValueScenario(),
    "OK",
    "a binary secret must always come back as a typed BinaryValueUnsupported error, never a silent Ok(null)"
  )
}
