/// Grpc.Aspects — pub aspect templates for cross-cutting gRPC handler concerns.
///
/// Provides three reusable template aspects that mirror Web.Aspects but
/// target gRPC handlers (returning Result[T, GrpcStatus]).
///
///   RequiresGrpcAuth    — validates a bearer token; UNAUTHENTICATED (16) /
///                         PERMISSION_DENIED (7) on failure.
///                         C-mode (@inline_template): reads args.authToken.
///                         The gRPC kernel extracts the token from the
///                         "authorization" metadata header and passes it as
///                         the `authToken: String` handler parameter.
///
///   RequiresGrpcRole    — validates token AND checks a role claim.
///                         C-mode: reads args.authToken.
///
///   GrpcRateLimit       — per-method sliding-window rate limit; RESOURCE_EXHAUSTED
///                         (8) on excess.  B-mode: uses call.qualifiedName.
///
///   GrpcCircuitBreaker  — open-circuit short-circuit; UNAVAILABLE (14) when open.
///                         B-mode: uses call.qualifiedName.
///
/// Both auth aspects delegate to lyric-auth (Auth.verifyJwt, Auth.rolesContain).
/// GrpcCircuitBreaker delegates to lyric-resilience (Resilience.circuitIsOpen, etc.).
/// The same underlying functions are used by Web.Aspects, so a single
/// lyric-auth configuration covers HTTP and gRPC services uniformly.
///
/// Typical consumer instantiation:
///
///   import Grpc.Aspects
///
///   aspect GrpcAuth from Grpc.Aspects.RequiresGrpcAuth {
///     matches: name like "get*" || name like "list*" || name like "create*"
///             || name like "update*" || name like "delete*"
///   }
///
///   aspect GrpcCircuit from Grpc.Aspects.GrpcCircuitBreaker {
///     matches: name like "get*" || name like "list*" || name like "create*"
///             || name like "update*" || name like "delete*"
///     inside: GrpcAuth
///   }
///
/// See docs/37-grpc-proto-sketch.md §6.2.

@runtime_checked
package Grpc.Aspects

import Std.Core
import Grpc
import Auth
import Resilience

// ─── RequiresGrpcAuth ─────────────────────────────────────────────────────────

/// Validate a bearer token on every matched gRPC handler call.
///
/// The handler must declare a parameter named `authToken: String`.  The gRPC
/// kernel extracts the token from the "authorization" metadata header (stripping
/// the "Bearer " prefix if present) and passes it as this parameter.
///
/// When the token is absent or invalid, the call is short-circuited with
/// GrpcStatus 16 (UNAUTHENTICATED) or 7 (PERMISSION_DENIED).
///
/// Delegates to Auth.verifyJwt — the same function used by Web.Aspects.RequiresAuth.
///
/// This is a C-mode template (@inline_template): reads args.authToken.
///
/// Config fields:
///   enabled   Bool   — master switch (default: true)
///   @sensitive
///   jwtSecret String — REQUIRED: HMAC-SHA256 or RS256 signing secret
///   issuer    String — expected iss claim; empty = skip check (default: "")
///   audience  String — expected aud claim; empty = skip check (default: "")
@stable(since="0.1")
@inline_template
pub aspect RequiresGrpcAuth {
  config {
    enabled: Bool   = true
    @sensitive
    jwtSecret: String
    issuer:    String = ""
    audience:  String = ""
  }

  requires:
    args.authToken != ""

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.authToken == "" {
        ret = Err(Grpc.unauthenticated("Authorization metadata missing"))
      } else {
        val ok = Auth.verifyJwt(args.authToken, jwtSecret, issuer, audience)
        if ok {
          ret = call.proceed()
        } else {
          ret = Err(Grpc.permissionDenied("Token is invalid or has expired"))
        }
      }
    }
  }
}

// ─── RequiresGrpcRole ─────────────────────────────────────────────────────────

/// Validate a bearer token AND assert the caller holds a required role.
///
/// First verifies the JWT (same rules as RequiresGrpcAuth), then extracts
/// the `role` claim and checks it against `allowedRoles`.
///
/// C-mode template (@inline_template): reads args.authToken.
///
/// Config fields:
///   enabled      Bool   — master switch (default: true)
///   @sensitive
///   jwtSecret    String — REQUIRED: signing secret
///   issuer       String — expected iss claim (default: "")
///   audience     String — expected aud claim (default: "")
///   allowedRoles String — comma-separated accepted role values (e.g. "admin,editor")
@stable(since="0.1")
@inline_template
pub aspect RequiresGrpcRole {
  config {
    enabled: Bool   = true
    @sensitive
    jwtSecret:    String
    issuer:       String = ""
    audience:     String = ""
    allowedRoles: String
  }

  requires:
    args.authToken != ""

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.authToken == "" {
        ret = Err(Grpc.unauthenticated("Authorization metadata missing"))
      } else {
        val ok = Auth.verifyJwt(args.authToken, jwtSecret, issuer, audience)
        if not ok {
          ret = Err(Grpc.permissionDenied("Token is invalid or has expired"))
        } else {
          val claimOpt = Auth.extractClaim(args.authToken, "role")
          match claimOpt {
            case None ->
              ret = Err(Grpc.permissionDenied("Token does not carry a role claim"))
            case Some(roleValue) -> {
              if Auth.rolesContain(allowedRoles, roleValue) {
                ret = call.proceed()
              } else {
                ret = Err(Grpc.permissionDenied("Insufficient role: " + roleValue))
              }
            }
          }
        }
      }
    }
  }
}

// ─── GrpcRateLimit ────────────────────────────────────────────────────────────

/// Enforce a per-method call rate limit.
///
/// Uses call.qualifiedName as the rate-limit key.  When the limit is
/// exceeded the call is short-circuited with 8 RESOURCE_EXHAUSTED.
///
/// B-mode: does not read named fields off args; applies generically.
///
/// Config fields:
///   enabled           Bool — master switch (default: true)
///   requestsPerMinute Int  — maximum calls per 60-second window (default: 600)
///   burstSize         Int  — maximum calls in a single second (default: 50)
@stable(since="0.1")
pub aspect GrpcRateLimit {
  config {
    enabled:           Bool = true
    requestsPerMinute: Int  = 600
    burstSize:         Int  = 50
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val allowed = Grpc.Kernel.Net.checkRateLimit(call.qualifiedName, requestsPerMinute, burstSize)
      if allowed {
        ret = call.proceed()
      } else {
        ret = Err(Grpc.resourceExhausted("Rate limit exceeded — retry after 60 seconds"))
      }
    }
  }
}

// ─── GrpcCircuitBreaker ───────────────────────────────────────────────────────

/// gRPC-specific circuit breaker: open circuit returns 14 UNAVAILABLE.
///
/// Wraps Resilience.* kernel helpers and maps open-circuit failure to
/// GrpcStatus (UNAVAILABLE) so it composes correctly with gRPC handlers.
///
/// B-mode: uses call.qualifiedName as the circuit name unless `name` is set.
///
/// Config fields:
///   enabled          Bool   — master switch (default: true)
///   name             String — circuit name; defaults to call.qualifiedName (default: "")
///   failureThreshold Int    — consecutive failures before opening (default: 5)
///   cooldownMs       Int    — ms before probing after open (default: 30000)
@stable(since="0.1")
pub aspect GrpcCircuitBreaker {
  config {
    enabled:          Bool   = true
    name:             String = ""
    failureThreshold: Int    = 5
    cooldownMs:       Int    = 30000
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = if name.length > 0 then name else call.qualifiedName
      if Resilience.circuitIsOpen(key, cooldownMs) {
        ret = Err(Grpc.unavailable(key + " is temporarily unavailable"))
      } else {
        ret = call.proceed()
        match ret {
          case Ok(_)  -> Resilience.circuitRecordSuccess(key)
          case Err(_) -> Resilience.circuitRecordFailure(key, failureThreshold)
        }
      }
    }
  }
}
