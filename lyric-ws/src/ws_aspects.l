// Ws.Aspects — pub aspect templates for WebSocket handler cross-cutting concerns.
//
// Provides two reusable template aspects:
//
//   WsAuth      — validates a bearer token from the WebSocket handshake headers
//                 before the connection upgrade completes.  C-mode (@inline_template):
//                 reads args.ctx.headers to find the Authorization header.
//
//   WsRateLimit — per-connection message rate limit.  B-mode: uses
//                 call.qualifiedName + args.ctx.connectionId as the rate key,
//                 so each (handler, connection) pair has its own counter.
//
// Auth delegates to lyric-auth (Auth.verifyJwt) for transport-agnostic
// token verification — the same JWT logic used by HTTP and gRPC handlers.
//
// Typical consumer instantiation:
//
//   import Ws.Aspects
//
//   aspect WsAuthGate from Ws.Aspects.WsAuth {
//     matches: name like "onOpen*"
//   }
//
//   aspect WsThrottle from Ws.Aspects.WsRateLimit {
//     matches: name like "onMessage*"
//     config { messagesPerMinute: Int = 60 }
//   }
//
// See docs/26-aspects.md and docs/27-aspect-libraries.md.

@runtime_checked
package Ws.Aspects

import Std.Core
import Ws
import Auth
import Ws.Kernel.Net
import Ws.Kernel.Jvm

// ─── WsAuth ───────────────────────────────────────────────────────────────────

/// Validate a bearer token from the WebSocket handshake Authorization header.
///
/// Apply to `onOpen` handlers.  The aspect reads args.ctx.headers, looks up
/// the "Authorization" or "authorization" key, strips the "Bearer " prefix,
/// and verifies the token against the configured JWT secret.
///
/// When the token is absent or invalid the call is short-circuited and an
/// Err(WsError) is returned without invoking the handler, which causes the
/// kernel to close the connection before it is accepted.
///
/// This is a C-mode template (@inline_template): body is re-compiled inside
/// the consumer's package so it can read args.ctx.headers.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled            Bool   — master switch; false passes all upgrades through (default: true)
///   @sensitive
///   jwtSecret          String — REQUIRED: HMAC-SHA256 secret for JWT verification
///   issuer             String — expected iss claim; empty skips issuer check (default: "")
///   audience           String — expected aud claim; empty skips audience check (default: "")
///   allowedAlgorithms  String — comma-separated allow-list of `alg` values
///                               (default: "HS256").  See RFC 8725 §3.1.
@stable(since="0.1")
@inline_template
pub aspect WsAuth {
  config {
    enabled: Bool   = true
    @sensitive
    jwtSecret: String          // required — no default
    issuer:    String = ""
    audience:  String = ""
    allowedAlgorithms: String = "HS256"
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val headers = args.ctx.headers
      val connId  = args.ctx.connectionId
      val authVal = match headers.get("Authorization") {
        case Some(v) -> v
        case None    ->
          match headers.get("authorization") {
            case Some(v) -> v
            case None    -> ""
          }
      }
      if authVal == "" {
        ret = Err(WsError(
          message      = "Authorization header missing",
          code         = "UNAUTHORIZED",
          connectionId = connId))
      } else {
        val prefix = "Bearer "
        val token = if authVal.length > prefix.length and authVal.substring(0, prefix.length) == prefix {
          authVal.substring(prefix.length, authVal.length)
        } else {
          ""
        }
        if token == "" {
          ret = Err(WsError(
            message      = "unauthorized: invalid token format",
            code         = "UNAUTHORIZED",
            connectionId = connId))
        } else {
          val ok = Auth.verifyJwt(token, jwtSecret, issuer, audience, allowedAlgorithms)
          if ok {
            ret = call.proceed()
          } else {
            ret = Err(WsError(
              message      = "Token is invalid or has expired",
              code         = "FORBIDDEN",
              connectionId = connId))
          }
        }
      }
    }
  }
}

// ─── WsRateLimit ─────────────────────────────────────────────────────────────

/// Enforce a per-connection message rate limit on WebSocket message handlers.
///
/// Uses call.qualifiedName + args.ctx.connectionId as the rate-limit key so
/// each (handler function, connection) pair has an independent sliding-window
/// counter.  When the limit is exceeded the call is short-circuited with
/// Err(WsError(code="RATE_LIMITED")) without invoking the handler.
///
/// Rate-limit state is maintained by the kernel (in-process sliding window
/// keyed by the composite string).
///
/// B-mode: the body does not read named fields off args beyond args.ctx,
/// so it composes generically across onMessage and any other handlers
/// that accept a WsContext first parameter.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled           Bool — master switch (default: true)
///   messagesPerMinute Int  — max messages allowed per 60-second window (default: 120)
///   burstSize         Int  — max messages allowed in a single second (default: 20)
@stable(since="0.1")
pub aspect WsRateLimit {
  config {
    enabled:           Bool = true
    messagesPerMinute: Int  = 120
    burstSize:         Int  = 20
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val rateKey = call.qualifiedName + ":" + args.ctx.connectionId
      val allowed = wsAspectKernelCheckRateLimit(rateKey, messagesPerMinute, burstSize)
      if allowed {
        ret = call.proceed()
      } else {
        ret = Err(WsError(
          message      = "Message rate limit exceeded",
          code         = "RATE_LIMITED",
          connectionId = args.ctx.connectionId))
      }
    }
  }
}

// ─── Kernel dispatchers (target-gated) ────────────────────────────────────────

@cfg(feature = "dotnet")
func wsAspectKernelCheckRateLimit(key: in String, messagesPerMinute: in Int, burstSize: in Int): Bool {
  return Ws.Kernel.Net.checkRateLimit(key, messagesPerMinute, burstSize)
}
@cfg(feature = "jvm")
func wsAspectKernelCheckRateLimit(key: in String, messagesPerMinute: in Int, burstSize: in Int): Bool {
  return Ws.Kernel.Jvm.checkRateLimit(key, messagesPerMinute, burstSize)
}
