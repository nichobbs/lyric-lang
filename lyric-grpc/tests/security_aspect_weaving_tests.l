//! tests/security_aspect_weaving_tests.l — runtime weaving tests for the
//! security-critical Grpc.Aspects templates (RequiresGrpcAuth / RequiresGrpcRole).
//!
//! These aspects previously carried a `requires: args.authToken != ""` clause,
//! which elaborates into a runtime precondition assert (D118) that PANICKED the
//! server process when a gRPC call arrived with missing/empty auth-token
//! metadata — the same unauthenticated-DoS class fixed for `lyric-web`. The fix
//! removed the clause and relies on the aspect body's own empty-case branch,
//! which fails closed with 16 UNAUTHENTICATED. These tests pin that: an empty
//! token must return a graceful status, never crash the process.
@test_module
package Grpc.SecurityAspectWeavingTests

import Std.Core
import Std.Testing
import Grpc.Types
import Grpc
import Grpc.Aspects

// Guard any handler named `authGuarded*` with the RequiresGrpcAuth template.
aspect AuthGuard from Grpc.Aspects.RequiresGrpcAuth {
  matches: name like "authGuarded*"
  config {
    jwtSecret: String = "lyric-test-hs256-signing-key-0123456789"
    issuer: String = "lyric-tests"
    audience: String = "lyric-tests-api"
  }
}

pub func authGuardedHandler(authToken: in String): Result[String, GrpcStatus] {
  return Std.Core.Ok("authorized")
}

test "RequiresGrpcAuth: an empty token returns UNAUTHENTICATED without crashing (was a panic)" {
  match authGuardedHandler("") {
    case Ok(_) -> assertTrue(false, "an empty token must be rejected before the handler runs")
    case Err(status) -> match status.code {
      case GrpcStatusCode.Unauthenticated -> assertTrue(
        true,
        "empty token short-circuits with UNAUTHENTICATED"
      )
      case _ -> assertTrue(false, "empty token must map to UNAUTHENTICATED, not another status")
    }
  }
}

test "RequiresGrpcAuth: a non-empty but invalid token is denied without crashing" {
  match authGuardedHandler("not.a.valid.jwt") {
    case Ok(_) -> assertTrue(false, "an unverifiable token must be rejected before the handler runs")
    case Err(status) -> match status.code {
      case GrpcStatusCode.PermissionDenied -> assertTrue(
        true,
        "invalid token short-circuits with PERMISSION_DENIED"
      )
      case _ -> assertTrue(false, "invalid token must map to PERMISSION_DENIED")
    }
  }
}

// Guard any handler named `roleGuarded*` with the RequiresGrpcRole template.
aspect RoleGuard from Grpc.Aspects.RequiresGrpcRole {
  matches: name like "roleGuarded*"
  config {
    jwtSecret: String = "lyric-test-hs256-signing-key-0123456789"
    issuer: String = "lyric-tests"
    audience: String = "lyric-tests-api"
    allowedRoles: String = "admin"
  }
}

pub func roleGuardedHandler(authToken: in String): Result[String, GrpcStatus] {
  return Std.Core.Ok("authorized")
}

test "RequiresGrpcRole: an empty token returns UNAUTHENTICATED without crashing (was a panic)" {
  match roleGuardedHandler("") {
    case Ok(_) -> assertTrue(false, "an empty token must be rejected before the handler runs")
    case Err(status) -> match status.code {
      case GrpcStatusCode.Unauthenticated -> assertTrue(
        true,
        "empty token short-circuits with UNAUTHENTICATED"
      )
      case _ -> assertTrue(false, "empty token must map to UNAUTHENTICATED, not another status")
    }
  }
}

// A placeholder secret shorter than 32 bytes is a configuration error for
// every call, whatever its token (#7319).
aspect ShortSecretGuard from Grpc.Aspects.RequiresGrpcAuth {
  matches: name like "shortSecretGuarded*"
  config {
    jwtSecret: String = "REPLACE_ME_WITH_A_REAL_SECRET"
    issuer: String = "lyric-tests"
    audience: String = "lyric-tests-api"
  }
}

pub func shortSecretGuardedHandler(authToken: in String): Result[String, GrpcStatus] {
  return Std.Core.Ok("reached")
}

test "RequiresGrpcAuth: a short jwtSecret is a configuration error, even for an empty token" {
  assertPanicsWith("short secret", "jwtSecret must be at least 32 bytes", { -> val _ = shortSecretGuardedHandler("") })
}

// A breaker configuration that cannot work is reported before the handler
// runs (#7331).
aspect ZeroCooldownBreaker from Grpc.Aspects.GrpcCircuitBreaker {
  matches: name like "breakerMisconfigured*"
  config {
    cooldownMs: Int = 0
  }
}

pub func breakerMisconfiguredHandler(): Result[String, GrpcStatus] {
  return Std.Core.Ok("reached")
}

test "GrpcCircuitBreaker: cooldownMs 0 fails before the handler runs" {
  assertPanicsWith("zero cooldown", "cooldownMs", { -> val _ = breakerMisconfiguredHandler() })
}
