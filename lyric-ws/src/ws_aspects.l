//! Ws.Aspects — pub aspect templates for WebSocket handler cross-cutting concerns.
//!
//! See docs/26-aspects.md and docs/27-aspect-libraries.md.
@runtime_checked
package Ws.Aspects

import Std.Core
import Std.Console
import Auth
import Ws.Kernel.Net as WsKernel

// ─── WsAuth ───────────────────────────────────────────────────────────────────
/// Validate a bearer token from the WebSocket handshake Authorization header.
///
/// Row-constrained B'-mode (docs/56 / D115): reads `args.authToken` via a
/// `where TArgs has { authToken: String }` row clause.  The handler must
/// declare an `authToken: String` parameter.
@stable(since = "0.1")
pub aspect WsAuth {
  config {
    enabled: Bool = true
    @sensitive
    jwtSecret: String
    issuer: String = ""
    audience: String = ""
    allowedAlgorithms: String = "HS256"
  }
  around(call) -> ret where TArgs has { authToken: String } {
    if not enabled {
      ret = call.proceed()
    } else {
      match Auth.verifyJwt(args.authToken, jwtSecret, issuer, audience, allowedAlgorithms) {
        case Ok(unit) -> {
          ret = call.proceed()
        }
        case Err(jwtErr) -> {
          // `ret` is `Result[Unit, Unit]` — we can't carry the error
          // code in the return value, but surfacing it via stderr lets
          // operators correlate failed connections with token issues
          // (#1156).
          Console.error("WsAuth: JWT verify failed: " + jwtErr.code)
          ret = Err(())
        }
      }
    }
  }
}

// ─── WsRateLimit ─────────────────────────────────────────────────────────────
/// Enforce a per-connection message rate limit on WebSocket message handlers.
///
/// Row-constrained B'-mode (docs/56 / D115): reads `args.ctx.connectionId`
/// via a `where TArgs has { ctx: WsContext }` row clause.  The handler must
/// declare a `ctx: WsContext` parameter.
@stable(since = "0.1")
pub aspect WsRateLimit {
  config {
    enabled: Bool = true
    messagesPerMinute: Int = 120
    burstSize: Int = 20
  }
  around(call) -> ret where TArgs has { ctx: WsContext } {
    if not enabled {
      ret = call.proceed()
    } else {
      val rateKey = call.qualifiedName + ":" + args.ctx.connectionId
      val allowed = WsKernel.checkRateLimit(rateKey, messagesPerMinute, burstSize)
      if allowed {
        ret = call.proceed()
      } else {
        ret = Err(())
      }
    }
  }
}
