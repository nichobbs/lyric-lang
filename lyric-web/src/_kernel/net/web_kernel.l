// Web.Kernel.Net — ASP.NET Core / Kestrel extern boundary.
//
// Bridges Lyric's Web package to the .NET HTTP stack:
//   - serve()           — starts the Kestrel server with the given router data
//   - checkRateLimit()  — sliding-window rate limiter (in-process)
//
// JWT verification lives in Auth.Kernel.Net (lyric-auth); call Auth.verifyJwt
// rather than accessing the extern directly.
//
// All functions are @cfg(feature = "dotnet") so they are erased when the
// dotnet feature is not active (e.g. during JVM builds — Phase 6).
//
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Web.Kernel.Net

import Std.Core

// ─── HTTP server ──────────────────────────────────────────────────────────────

/// Start the HTTP server.  Blocks until SIGTERM / SIGINT.
/// Routes are passed as parallel slices (method, pattern, handlerName, summary).
/// Workers are passed as parallel slices (name, intervalMs, handlerName).
@axiom("ASP.NET Core Kestrel HTTP server and minimal-API routing")
pub func serve(
  host:            String,
  port:            Int,
  swaggerEnabled:  Bool,
  specPath:        String,
  corsEnabled:     Bool,
  corsOrigins:     String,
  corsMethods:     String,
  corsHeaders:     String,
  corsMaxAge:      Int,
  routeMethods:    slice[String],
  routePatterns:   slice[String],
  routeHandlers:   slice[String],
  routeSummaries:  slice[String],
  workerNames:     slice[String],
  workerIntervals: slice[Int],
  workerHandlers:  slice[String]
): Unit = ()

// ─── Rate limiting ────────────────────────────────────────────────────────────

/// Check whether a call from this endpoint is within the rate limit.
/// Returns true (allow) or false (deny).
/// State is per-process and per-endpoint; resets on process restart.
@axiom("In-process sliding-window rate limiter (System.Threading.RateLimiting)")
pub func checkRateLimit(
  endpoint:          String,
  requestsPerMinute: Int,
  burstSize:         Int
): Bool = false
