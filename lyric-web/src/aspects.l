/// Web.Aspects — pub aspect templates for cross-cutting HTTP handler concerns.
///
/// Provides two reusable template aspects:
///
///   RequiresAuth  — validates a bearer token before proceeding; returns
///                   401 Unauthorized or 403 Forbidden on failure.
///                   C-mode (@inline_template): body reads args.authToken,
///                   so it is re-compiled in the consumer's package.
///                   Only applicable to handlers with an `authToken: String`
///                   parameter; the compiler reports a shape error otherwise
///                   (A0042 per docs/27-aspect-libraries.md §9.1).
///
///   RateLimit     — enforces a per-endpoint call rate; returns 429 Too Many
///                   Requests when the limit is exceeded.
///                   B-mode: uses call.qualifiedName as the rate-limit key,
///                   so the endpoint identity is always available without
///                   accessing named fields on args.
///
/// Typical consumer instantiation:
///
///   import Web.Aspects
///
///   aspect Auth from Web.Aspects.RequiresAuth {
///     matches: name like "handle*"
///     except name in { handleHealth, handleOpenApiSpec }
///   }
///
///   aspect Throttle from Web.Aspects.RateLimit {
///     matches: name like "handle*"
///     inside:  Auth
///     config {
///       requestsPerMinute: Int = 30
///     }
///   }
///
/// CORS is not an aspect — it applies to all responses (including 404 and
/// OPTIONS preflight) at the HTTP middleware layer, not at the Lyric function
/// level.  Configure it via Web.Cors config block env vars instead.
///
/// See docs/26-aspects.md §18, docs/27-aspect-libraries.md.

@runtime_checked
package Web.Aspects

import Std.Core
import Web

// ─── RequiresAuth ─────────────────────────────────────────────────────────────

/// Validate a bearer token on every matched handler call.
///
/// The handler must declare a parameter named `authToken: String` (the value
/// extracted from the Authorization header by the framework's dispatcher).
/// When the token is absent or invalid this aspect short-circuits and returns
/// a 401 or 403 error without calling the handler.
///
/// This is a C-mode template (@inline_template): the body is re-compiled
/// inside the consumer's package so it can read args.authToken on the
/// concrete handler parameter list.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled     Bool    — master switch; false passes all calls through (default: true)
///   @sensitive
///   jwtSecret   String  — REQUIRED (no default): HMAC-SHA256 secret for JWT verification
///   issuer      String  — expected JWT issuer claim; if empty, issuer is not validated (default: "")
///   audience    String  — expected JWT audience claim; if empty, audience is not validated (default: "")
@stable(since="0.1")
@inline_template
pub aspect RequiresAuth {
  config {
    enabled:  Bool   = true
    @sensitive
    jwtSecret: String          // required — no default
    issuer:   String = ""
    audience: String = ""
  }

  requires:
    args.authToken != ""       // handler must have an authToken parameter

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.authToken == "" {
        ret = Err(Web.unauthorized("Authorization header missing or empty"))
      } else {
        val ok = Web.Kernel.Net.verifyJwt(args.authToken, jwtSecret, issuer, audience)
        if ok {
          ret = call.proceed()
        } else {
          ret = Err(Web.forbidden("Token is invalid or has expired"))
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
@stable(since="0.1")
pub aspect RateLimit {
  config {
    enabled:           Bool = true
    requestsPerMinute: Int  = 60
    burstSize:         Int  = 10
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val allowed = Web.Kernel.Net.checkRateLimit(call.qualifiedName, requestsPerMinute, burstSize)
      if allowed {
        ret = call.proceed()
      } else {
        ret = Err(Web.tooManyRequests("Rate limit exceeded — try again later"))
      }
    }
  }
}
