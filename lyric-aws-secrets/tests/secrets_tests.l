//! tests/secrets_tests.l — tests for the pure-Lyric surface of lyric-aws-secrets.
//!
//! Covers SecretsError union construction and errorMessage formatting.
//! The init(), getSecret(), getParameter(), and related functions require live
//! AWS Secrets Manager or Parameter Store credentials and are not tested here.
@test_module
package AwsSecrets.SecretsTests

import Std.Core
import Std.Testing
import AwsSecrets

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
