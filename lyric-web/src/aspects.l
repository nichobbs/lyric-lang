//! Web.Aspects — pub aspect templates for cross-cutting HTTP handler concerns.
//!
//! Provides five reusable template aspects:
//!
//!   RequiresAuth        — validates a bearer token; 401 / 403 on failure.
//!                         Row-constrained B'-mode (docs/56): reads
//!                         args.authToken via `where TArgs has { authToken: String }`.
//!   RequiresRole        — validates token AND checks a role claim; 403 on
//!                         insufficient role.  Row-constrained B'-mode: reads
//!                         args.authToken.
//!   ApiKey              — constant-time API-key check; 401 on mismatch.
//!                         Row-constrained B'-mode: reads args.apiKey.
//!   RateLimit           — per-endpoint sliding-window rate limit; 429 on
//!                         excess.  B-mode: uses call.qualifiedName.
//!   HttpCircuitBreaker  — open-circuit short-circuit; 503 when open.
//!                         B-mode: uses call.qualifiedName.
//!
//! Auth aspects delegate to lyric-auth (Auth.verifyJwt, Auth.extractClaim,
//! Auth.verifyApiKey, Auth.rolesContain) so the JWT and API-key logic is
//! transport-agnostic and can be reused from gRPC or queue aspects.
//!
//! Typical consumer instantiation:
//!
//!   import Web.Aspects
//!
//!   aspect Auth from Web.Aspects.RequiresAuth {
//!     matches: name like "handle*"
//!     except name in { handleHealth, handleOpenApiSpec }
//!   }
//!
//!   aspect Throttle from Web.Aspects.RateLimit {
//!     matches: name like "handle*"
//!     inside:  Auth
//!     config { requestsPerMinute: Int = 30 }
//!   }
//!
//!   aspect Circuit from Web.Aspects.HttpCircuitBreaker {
//!     matches: name like "handle*"
//!     inside:  Throttle
//!   }
//!
//! CORS is not an aspect — configure it via env vars (see Web.start).
//!
//! See docs/26-aspects.md §18, docs/27-aspect-libraries.md.
@runtime_checked
package Web.Aspects

import Std.Core
import Std.Console
import Web as WebPkg
import Auth
import Resilience
import Web.Kernel.Runtime as HttpKernel

// ─── RequiresAuth ─────────────────────────────────────────────────────────────
/// Validate a bearer token on every matched handler call.
///
/// The handler must declare a parameter named `authToken: String` (the value
/// extracted from the Authorization header by the framework's dispatcher).
/// When the token is absent or invalid this aspect short-circuits and returns
/// a 401 or 403 error without calling the handler.
///
/// Delegates to Auth.verifyJwt (lyric-auth) for transport-agnostic token
/// verification.  This is a row-constrained B'-mode template (docs/56 /
/// D115): the `where TArgs has { authToken: String }` clause declares the
/// field the body needs, so weaving shares one specialised function across
/// every matched handler while still typed-accessing args.authToken.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled            Bool   — master switch; false passes all calls through (default: true)
///   @sensitive
///   jwtSecret          String — REQUIRED: HMAC-SHA256 secret for JWT verification
///   issuer             String — expected JWT issuer claim; if empty, issuer is not validated (default: "")
///   audience           String — expected JWT audience claim; if empty, audience is not validated (default: "")
///   allowedAlgorithms  String — comma-separated allow-list of `alg` values
///                               (default: "HS256").  Tokens whose `alg` header is
///                               not in this list — including `alg=none` — are
///                               rejected.  See RFC 8725 §3.1.
@stable(since = "0.1")
pub aspect RequiresAuth {
  config {
    enabled: Bool = true
    @sensitive
    jwtSecret: String          // required — no default
    issuer: String = ""
    audience: String = ""
    allowedAlgorithms: String = "HS256"
  }
  requires: args.authToken != ""
  // handler must have an authToken parameter
  around(call) -> ret where TArgs has { authToken: String } {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.authToken == "" {
        ret = Err(WebPkg.unauthorized("Authorization header missing or empty"))
      } else {
        match Auth.verifyJwt(args.authToken, jwtSecret, issuer, audience, allowedAlgorithms) {
          case Ok(_) -> {
            ret = call.proceed()
          }
          case Err(jwtErr) -> {
            // Log the precise reason to stderr for operators; return a
            // generic message to the client so we don't leak which
            // failure mode triggered (expired vs invalid signature vs
            // wrong issuer/audience) — #1266.
            Console.error("RequiresAuth: JWT verify failed: " + jwtErr.code)
            ret = Err(WebPkg.forbidden("Token is invalid or has expired"))
          }
        }
      }
    }
  }
}

// ─── RequiresRole ─────────────────────────────────────────────────────────────
/// Validate a bearer token AND assert the caller holds a required role.
///
/// The handler must declare a parameter named `authToken: String`.  The aspect
/// first verifies the JWT (same rules as RequiresAuth), then extracts the
/// `role` claim and checks it against `allowedRoles`.
///
/// This is a row-constrained B'-mode template (docs/56 / D115): reads
/// args.authToken via `where TArgs has { authToken: String }`.
///
/// Config fields:
///   enabled            Bool   — master switch (default: true)
///   @sensitive
///   jwtSecret          String — REQUIRED: HMAC-SHA256 or RS256 secret
///   issuer             String — expected iss claim (default: "")
///   audience           String — expected aud claim (default: "")
///   allowedRoles       String — comma-separated list of accepted role values (e.g. "admin,manager")
///   allowedAlgorithms  String — comma-separated allow-list of `alg` values (default: "HS256")
@stable(since = "0.1")
pub aspect RequiresRole {
  config {
    enabled: Bool = true
    @sensitive
    jwtSecret: String
    issuer: String = ""
    audience: String = ""
    allowedRoles: String        // required — no default
    allowedAlgorithms: String = "HS256"
  }
  requires: args.authToken != ""
  around(call) -> ret where TArgs has { authToken: String } {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.authToken == "" {
        ret = Err(WebPkg.unauthorized("Authorization header missing or empty"))
      } else {
        match Auth.verifyJwt(args.authToken, jwtSecret, issuer, audience, allowedAlgorithms) {
          case Err(jwtErr) -> {
            Console.error("RequiresRole: JWT verify failed: " + jwtErr.code)
            ret = Err(WebPkg.forbidden("Token is invalid or has expired"))
          }
          case Ok(_) -> {
            val claimOpt = Auth.extractClaim(args.authToken, "role")
            match claimOpt {
              case None -> {
                ret = Err(WebPkg.forbidden("Token does not carry a role claim"))
              }
              case Some(roleValue) -> {
                if Auth.rolesContain(allowedRoles, roleValue) {
                  ret = call.proceed()
                } else {
                  ret = Err(WebPkg.forbidden("Insufficient role: " + roleValue))
                }
              }
            }
          }
        }
      }
    }
  }
}

// ─── ApiKey ───────────────────────────────────────────────────────────────────
/// Validate a static API key on every matched handler call.
///
/// The handler must declare a parameter named `apiKey: String` (the value
/// extracted from the X-Api-Key header or query parameter by the dispatcher).
/// Uses constant-time comparison (Auth.verifyApiKey) to prevent timing attacks.
///
/// This is a row-constrained B'-mode template (docs/56 / D115): reads
/// args.apiKey via `where TArgs has { apiKey: String }`.
///
/// Config fields:
///   enabled     Bool   — master switch (default: true)
///   @sensitive
///   expectedKey String — REQUIRED: the accepted API key
@stable(since = "0.1")
pub aspect ApiKey {
  config {
    enabled: Bool = true
    @sensitive
    expectedKey: String
  }
  requires: args.apiKey != ""
  // required — no default
  around(call) -> ret where TArgs has { apiKey: String } {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.apiKey == "" {
        ret = Err(WebPkg.unauthorized("X-Api-Key header missing"))
      } else {
        val ok = Auth.verifyApiKey(args.apiKey, expectedKey)
        if ok {
          ret = call.proceed()
        } else {
          ret = Err(WebPkg.unauthorized("API key is invalid"))
        }
      }
    }
  }
}

// ─── RateLimit ────────────────────────────────────────────────────────────────
/// Enforce a per-endpoint call rate limit.
///
/// Uses call.qualifiedName as the rate-limit key so each handler has an
/// independent counter.  When the limit is exceeded the call is short-
/// circuited with 429 Too Many Requests without invoking the handler.
///
/// Rate-limit state is maintained by the kernel (in-process sliding window
/// by default; configurable for distributed deployments).
///
/// This is B-mode (default): the body does not read named fields off args,
/// so it composes generically across all matched handlers.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled           Bool — master switch (default: true)
///   requestsPerMinute Int  — maximum allowed calls per 60-second window (default: 60)
///   burstSize         Int  — maximum calls allowed in a single second (default: 10)
@stable(since = "0.1")
pub aspect RateLimit {
  config {
    enabled: Bool = true
    requestsPerMinute: Int = 60
    burstSize: Int = 10
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val allowed = HttpKernel.checkRateLimit(call.qualifiedName, requestsPerMinute, burstSize)
      if allowed {
        ret = call.proceed()
      } else {
        ret = Err(WebPkg.tooManyRequests("Rate limit exceeded — try again later"))
      }
    }
  }
}

// ─── HttpCircuitBreaker ───────────────────────────────────────────────────────
/// HTTP-specific circuit breaker: open circuit returns 503 Service Unavailable.
///
/// Wraps the transport-agnostic Resilience.CircuitBreaker logic and maps the
/// open-circuit failure to ApiError (503) instead of Err(String), so it
/// composes correctly with HTTP handler return types (Result[T, ApiError]).
///
/// When the circuit is open, handlers are short-circuited with
/// 503 Service Unavailable without invoking the underlying function.
/// After `cooldownMs` the circuit transitions to half-open; one probe call
/// is allowed through.  A successful probe closes the circuit.
///
/// B-mode: uses call.qualifiedName as the circuit name unless `name` is set.
///
/// Config fields:
///   enabled          Bool   — master switch (default: true)
///   name             String — circuit name; defaults to call.qualifiedName (default: "")
///   failureThreshold Int    — consecutive failures before opening (default: 5)
///   cooldownMs       Int    — ms to wait before probing again (default: 30000)
@stable(since = "0.1")
pub aspect HttpCircuitBreaker {
  config {
    enabled: Bool = true
    name: String = ""
    failureThreshold: Int = 5
    cooldownMs: Int = 30000
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = if name.length > 0 then name else call.qualifiedName
      if Resilience.circuitIsOpen(key, cooldownMs) {
        ret = Err(WebPkg.serviceUnavailable(key + " is temporarily unavailable"))
      } else {
        ret = call.proceed()
        match ret {
          case Ok(_) -> Resilience.circuitRecordSuccess(key)
          case Err(_) -> Resilience.circuitRecordFailure(key, failureThreshold)
        }
      }
    }
  }
}
