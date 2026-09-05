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
//! The AWS SDK (.NET) backend's live fetch behaviour stays NOT_IMPLEMENTED
//! (see `secrets_kernel_aws.l`'s header) and is not exercised here; the
//! JVM backend's real `SecretsManagerClient`/`SsmClient` network calls are
//! not exercised here either — no live or mocked AWS endpoint is set up in
//! this suite (see `secrets_kernel_jvm.l`'s header for the real bindings
//! this compiles against). Only the jvm kernel's pure-Lyric error
//! classification is covered.
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
// `secrets_kernel_aws.l` stays NOT_IMPLEMENTED — see that file's header for
// precisely why (a public-API-shape decision, not a missing compiler
// capability; the Task<T>-returning async SDK calls themselves ARE
// bindable, per the real `Std.HttpHost` precedent). These tests assert the
// honest failure contract: every call returns a real Err with a message
// naming the reason, never a silent Ok or an unhandled exception.
@cfg(feature = "aws")
func awsNotImplementedScenario(): String {
  val initResult = AwsSecrets.init()
  val secretResult = AwsSecrets.getSecret("my-service/prod")
  val paramResult = AwsSecrets.getParameter("/my-service/signing-key")
  match initResult {
    case Ok(_) -> return "init() must not silently succeed on the aws feature while NOT_IMPLEMENTED"
    case Err(_) -> ()
  }
  match secretResult {
    case Ok(_) -> return "getSecret() must not silently succeed on the aws feature while NOT_IMPLEMENTED"
    case Err(e) -> if AwsSecrets.errorMessage(e).contains("NOT_IMPLEMENTED") {
      ()
    } else {
      return "getSecret()'s error must say NOT_IMPLEMENTED, got: " + AwsSecrets.errorMessage(e)
    }
  }
  match paramResult {
    case Ok(_) -> "getParameter() must not silently succeed on the aws feature while NOT_IMPLEMENTED"
    case Err(e) -> if AwsSecrets.errorMessage(e).contains("NOT_IMPLEMENTED") {
      "OK"
    } else {
      "getParameter()'s error must say NOT_IMPLEMENTED, got: " + AwsSecrets.errorMessage(e)
    }
  }
}

@cfg(feature = "local")
func awsNotImplementedScenario(): String {
  "OK"
}

@cfg(feature = "jvm")
func awsNotImplementedScenario(): String {
  "OK"
}

test "aws kernel: init/getSecret/getParameter honestly return NOT_IMPLEMENTED, never a silent Ok" {
  assertEqual(
    awsNotImplementedScenario(),
    "OK",
    "the aws feature's kernel must fail every call with a documented NOT_IMPLEMENTED error"
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
