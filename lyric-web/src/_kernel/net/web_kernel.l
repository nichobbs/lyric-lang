/// Web.Kernel.Net — ASP.NET Core / Kestrel extern boundary.
///
/// Bridges Lyric's Web package to the .NET HTTP stack:
///   - serve()           — starts the Kestrel server with the given router
///   - verifyJwt()       — validates a Bearer token (HMAC-SHA256 or RS256)
///   - checkRateLimit()  — sliding-window rate limiter (in-process)
///
/// All functions are @cfg(feature = "dotnet") so they are erased when the
/// dotnet feature is not active (e.g. during JVM builds — Phase 6).
///
/// The dispatch model:
///   serve() registers each Route in the Router with ASP.NET Core minimal APIs.
///   For each incoming request the kernel:
///     1. Matches the request path + method against the route table.
///     2. Extracts {name} path segments and query parameters by name.
///     3. Deserializes the request body to the handler's @body parameter type
///        (JSON via System.Text.Json; Content-Type must be application/json).
///     4. Resolves the handler function from the DLL export table by its
///        qualified name string stored in Route.handlerName.
///     5. Invokes the handler via reflection, passing extracted parameters.
///     6. Serializes Result[T, ApiError] → HTTP response:
///          Ok(value)  → 200 + JSON body
///          Err(error) → error.status + JSON { "error": msg, "detail": [...] }
///     7. Applies CORS headers if Web.Cors.enabled = true.
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Web.Kernel.Net

import Web

// ─── HTTP server ──────────────────────────────────────────────────────────────

@axiom("ASP.NET Core Kestrel HTTP server and minimal-API routing")
extern package Microsoft.AspNetCore {
  /// Start the HTTP server.  Blocks until SIGTERM / SIGINT.
  pub func serve(
    host:              String,
    port:              Int,
    swaggerEnabled:    Bool,
    specPath:          String,
    corsEnabled:       Bool,
    corsOrigins:       String,
    corsMethods:       String,
    corsHeaders:       String,
    corsMaxAge:        Int,
    router:            Web.Router
  ): Unit
}

// ─── JWT verification ─────────────────────────────────────────────────────────

@axiom("System.IdentityModel.Tokens.Jwt for token validation")
extern package System.IdentityModel.Tokens.Jwt {
  /// Validate a Bearer token.
  /// Returns true if the token is well-formed, the signature verifies
  /// against `secret`, and the `issuer` / `audience` claims match when
  /// non-empty.  Returns false for any validation failure.
  pub func verifyJwt(
    token:    String,
    secret:   String,
    issuer:   String,
    audience: String
  ): Bool
    requires: secret.length > 0
}

// ─── Rate limiting ────────────────────────────────────────────────────────────

@axiom("In-process sliding-window rate limiter (System.Threading.RateLimiting)")
extern package System.Threading.RateLimiting {
  /// Check whether a call from this endpoint is within the rate limit.
  /// Returns true (allow) or false (deny).
  /// State is per-process and per-endpoint; resets on process restart.
  pub func checkRateLimit(
    endpoint:          String,
    requestsPerMinute: Int,
    burstSize:         Int
  ): Bool
    requires: requestsPerMinute > 0
    requires: burstSize > 0
}
