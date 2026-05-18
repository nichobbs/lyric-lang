// Web.Kernel.Net — ASP.NET Core / Kestrel extern boundary.
//
// Bridges Lyric's Web package to the .NET HTTP stack:
//   - serve()           — starts the Kestrel server with the given router
//   - checkRateLimit()  — sliding-window rate limiter (in-process)
//
// JWT verification lives in Auth.Kernel.Net (lyric-auth); call Auth.verifyJwt
// rather than accessing the extern directly.
//
// All functions are @cfg(feature = "dotnet") so they are erased when the
// dotnet feature is not active (e.g. during JVM builds — Phase 6).
//
// The dispatch model:
//   serve() registers each Route in the Router with ASP.NET Core minimal APIs,
//   and for each WorkerRegistration starts a background timer task.
//
//   For each incoming request the kernel:
//     1. Matches the request path + method against the route table.
//     2. Extracts {name} path segments and query parameters by name.
//     3. Deserializes the request body to the handler's @body parameter type
//        (JSON via System.Text.Json; Content-Type must be application/json).
//     4. Resolves the handler function from the DLL export table by its
//        qualified name string stored in Route.handlerName.
//     5. Invokes the handler via reflection, passing extracted parameters.
//     6. Serializes Result[T, ApiError] → HTTP response:
//          Ok(value)  → 200 + JSON body
//          Err(error) → error.status + JSON { "error": msg, "detail": [...] }
//     7. Applies CORS headers if Web.Cors.enabled = true.
//
//   For each WorkerRegistration the kernel:
//     1. Resolves the handler by qualified name (signature: () → Result[Unit, String]).
//     2. Fires it via a System.Threading.Timer on WorkerRegistration.intervalMs cadence.
//     3. Logs Err(message) results; Ok(()) results are silent.
//     4. Cancels all timers on graceful shutdown.
//
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

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
