//! Web.Kernel.Jvm — Undertow / JVM extern boundary.
//!
//! JVM implementation of the same contract as Web.Kernel.Net.  The HTTP
//! server is backed by io.undertow.Undertow; the in-process rate limiter
//! is backed by a custom lyric.web.RateLimiter helper (sliding-window,
//! per-endpoint, in-process state).
//!
//! The dispatch model mirrors Web.Kernel.Net exactly:
//!   serve() registers each Route in the Router with an Undertow
//!   RoutingHandler, and for each WorkerRegistration starts a
//!   ScheduledExecutorService task.
//!
//!   For each incoming request the kernel:
//!     1. Matches the request path + method against the route table.
//!     2. Extracts {name} path segments and query parameters by name.
//!     3. Deserializes the request body to the handler's @body parameter type
//!        (JSON via Jackson; Content-Type must be application/json).
//!     4. Resolves the handler function from the DLL export table by its
//!        qualified name string stored in Route.handlerName.
//!     5. Invokes the handler via reflection, passing extracted parameters.
//!     6. Serializes Result[T, ApiError] → HTTP response:
//!          Ok(value)  → 200 + JSON body
//!          Err(error) → error.status + JSON { "error": msg, "detail": [...] }
//!     7. Applies CORS headers if Web.Cors.enabled = true.
//!
//!   For each WorkerRegistration the kernel:
//!     1. Resolves the handler by qualified name (signature: () → Result[Unit, String]).
//!     2. Fires it via a ScheduledExecutorService on WorkerRegistration.intervalMs cadence.
//!     3. Logs Err(message) results; Ok(()) results are silent.
//!     4. Shuts down the executor on graceful shutdown.
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "jvm")
package Web.Kernel.Jvm

import Web

// ─── HTTP server ──────────────────────────────────────────────────────────────

@axiom("io.undertow.Undertow HTTP server and routing for JVM")
extern package lyric.web.UndertowServer {
  /// Start the HTTP server.  Blocks until the JVM receives SIGTERM / SIGINT.
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

@axiom("lyric.web.RateLimiter in-process sliding-window rate limiter for JVM")
extern package lyric.web.RateLimiter {
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

// ─── Re-exports ───────────────────────────────────────────────────────────────

/// Start the HTTP server.  Blocks until shutdown.
pub func serve(
  host:           in String,
  port:           in Int,
  swaggerEnabled: in Bool,
  specPath:       in String,
  corsEnabled:    in Bool,
  corsOrigins:    in String,
  corsMethods:    in String,
  corsHeaders:    in String,
  corsMaxAge:     in Int,
  router:         in Web.Router
): Unit {
  return lyric.web.UndertowServer.serve(
    host, port, swaggerEnabled, specPath,
    corsEnabled, corsOrigins, corsMethods, corsHeaders, corsMaxAge,
    router)
}

/// Check whether a call from this endpoint is within the rate limit.
pub func checkRateLimit(
  endpoint:          in String,
  requestsPerMinute: in Int,
  burstSize:         in Int
): Bool
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  return lyric.web.RateLimiter.checkRateLimit(endpoint, requestsPerMinute, burstSize)
}
