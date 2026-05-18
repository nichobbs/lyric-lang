/// Web — HTTP server foundation, type vocabulary, and routing.
///
/// Provides the ApiError type (with status-code constructor helpers),
/// the Router value type for building route tables, and the server
/// entry point backed by a runtime config block.
///
/// Route annotations (@get, @post, @put, @delete, @patch) are custom
/// annotations — apply them to handler functions and pass the handler's
/// qualified name to the router registration functions.  Discovery via
/// DLL reflection is planned once Lyric's annotation reflection ships.
///
/// Workflow — code-first:
///   1. Annotate handler functions with @get / @post / etc.
///   2. Register routes explicitly with addGet / addPost / etc.
///   3. Call Web.start(router) from main().
///   4. Run `lyric web spec` to emit openapi.yaml from the compiled DLL.
///
/// Workflow — spec-first:
///   1. Run `lyric generate openapi spec.yaml` → stub .l files.
///   2. Implement the generated handler bodies.
///   3. Register and start as above.
///
/// Runtime env vars (all read once at startup, fail-fast if invalid):
///   LYRIC_CONFIG_WEB_SERVER_HOST            — bind address (default: 0.0.0.0)
///   LYRIC_CONFIG_WEB_SERVER_PORT            — TCP port (default: 8080)
///   LYRIC_CONFIG_WEB_SERVER_SWAGGERENABLED  — serve Swagger UI at /swagger (default: false)
///   LYRIC_CONFIG_WEB_SERVER_SPECPATH        — OpenAPI spec URL path (default: /openapi.json)
///   LYRIC_CONFIG_WEB_CORS_ENABLED           — enable CORS middleware (default: false)
///   LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS    — comma-separated origins (no default; required when Cors.enabled = true)
///   LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS    — comma-separated HTTP methods
///   LYRIC_CONFIG_WEB_CORS_ALLOWEDHEADERS    — comma-separated header names
///   LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS     — preflight cache duration (default: 86400)

@runtime_checked
package Web

import Std.Core
import Std.Log
import Web.Kernel.Net as HttpKernel

// ─── ApiError ─────────────────────────────────────────────────────────────────

/// HTTP API error.  Handlers return Result[T, ApiError] where the error
/// carries the HTTP status code alongside a human-readable message.
/// Use the constructor helpers below rather than building ApiError directly.
@stable(since="0.1")
pub record ApiError {
  status:  Int
  message: String
  detail:  [String]
}

/// 400 Bad Request — malformed input, validation failure.
@stable(since="0.1")
pub func badRequest(message: in String): ApiError {
  return ApiError(status = 400, message = message, detail = [])
}

/// 400 with per-field validation messages.
@stable(since="0.1")
pub func badRequestWithDetail(message: in String, detail: in [String]): ApiError {
  return ApiError(status = 400, message = message, detail = detail)
}

/// 401 Unauthorized — missing or invalid credentials.
@stable(since="0.1")
pub func unauthorized(message: in String): ApiError {
  return ApiError(status = 401, message = message, detail = [])
}

/// 403 Forbidden — credentials valid but caller lacks permission.
@stable(since="0.1")
pub func forbidden(message: in String): ApiError {
  return ApiError(status = 403, message = message, detail = [])
}

/// 404 Not Found.
@stable(since="0.1")
pub func notFound(message: in String): ApiError {
  return ApiError(status = 404, message = message, detail = [])
}

/// 409 Conflict — state collision (duplicate key, optimistic lock, etc.).
@stable(since="0.1")
pub func conflict(message: in String): ApiError {
  return ApiError(status = 409, message = message, detail = [])
}

/// 422 Unprocessable Entity — well-formed request that fails domain rules.
@stable(since="0.1")
pub func unprocessable(message: in String, detail: in [String]): ApiError {
  return ApiError(status = 422, message = message, detail = detail)
}

/// 429 Too Many Requests.
@stable(since="0.1")
pub func tooManyRequests(message: in String): ApiError {
  return ApiError(status = 429, message = message, detail = [])
}

/// 500 Internal Server Error.
@stable(since="0.1")
pub func internalError(message: in String): ApiError {
  return ApiError(status = 500, message = message, detail = [])
}

/// 503 Service Unavailable — upstream dependency unreachable or degraded.
@stable(since="0.1")
pub func serviceUnavailable(message: in String): ApiError {
  return ApiError(status = 503, message = message, detail = [])
}

/// Arbitrary status code for cases not covered by the named constructors.
@stable(since="0.1")
pub func apiError(status: in Int, message: in String): ApiError
  requires: status >= 100
  requires: status <= 599
{
  return ApiError(status = status, message = message, detail = [])
}

// ─── HTTP primitives ──────────────────────────────────────────────────────────

/// A single HTTP header name-value pair.
@stable(since="0.1")
pub record Header {
  name:  String
  value: String
}

// ─── Router ───────────────────────────────────────────────────────────────────

/// A single registered route binding a method + URL pattern to a handler.
/// The handler is identified by its fully-qualified Lyric function name;
/// the kernel resolves it via DLL reflection at server startup.
///
/// Path parameters are embedded in the pattern as {name} segments and
/// extracted by name into handler parameters of matching names.
///
/// Query parameters are handler parameters whose names do not appear in
/// the path pattern; they are extracted from the query string.
///
/// The request body is delivered to the handler parameter annotated @body,
/// or to the last non-path, non-query parameter if no @body annotation
/// is present and the method has a body (POST, PUT, PATCH).
@stable(since="0.1")
pub record Route {
  method:      String
  pattern:     String
  handlerName: String    // fully-qualified Lyric function name
  summary:     String    // optional: becomes the OpenAPI operationId summary
  tags:        [String]  // optional: OpenAPI tags for grouping
  deprecated:  Bool
}

/// A background worker registered with the server.  The kernel starts one
/// timer per registration immediately after the HTTP server begins accepting
/// connections, and fires `handlerName` on the given interval until shutdown.
///
/// The handler must have the signature:
///   func myWorker(): Result[Unit, String]
/// where `Err(message)` causes the kernel to log the error and continue.
@stable(since="0.1")
pub record WorkerRegistration {
  name:        String   // human-readable label used in logs and health output
  intervalMs:  Int      // poll interval in milliseconds
  handlerName: String   // fully-qualified Lyric function name
}

/// A collection of routes and background workers.
/// Build one with create() then addGet/addPost/etc. and addWorker().
/// Compose multiple routers with merge() and scope them with prefix().
@stable(since="0.1")
pub record Router {
  routes:    [Route]
  workers:   [WorkerRegistration]
  pathPrefix: String
}

/// Empty router.
@stable(since="0.1")
pub func create(): Router {
  return Router(routes = [], workers = [], pathPrefix = "")
}

// Private route-insertion helper.
func addRoute(router: in Router, method: in String, pattern: in String, handlerName: in String): Router {
  val full = router.pathPrefix + pattern
  val route = Route(method = method, pattern = full, handlerName = handlerName, summary = "", tags = [], deprecated = false)
  return Router(routes = router.routes + [route], workers = router.workers, pathPrefix = router.pathPrefix)
}

/// Register a GET route.
@stable(since="0.1")
pub func addGet(router: in Router, pattern: in String, handlerName: in String): Router
  requires: pattern.length > 0
  requires: handlerName.length > 0
{
  return addRoute(router, "GET", pattern, handlerName)
}

/// Register a POST route.
@stable(since="0.1")
pub func addPost(router: in Router, pattern: in String, handlerName: in String): Router
  requires: pattern.length > 0
  requires: handlerName.length > 0
{
  return addRoute(router, "POST", pattern, handlerName)
}

/// Register a PUT route.
@stable(since="0.1")
pub func addPut(router: in Router, pattern: in String, handlerName: in String): Router
  requires: pattern.length > 0
  requires: handlerName.length > 0
{
  return addRoute(router, "PUT", pattern, handlerName)
}

/// Register a DELETE route.
@stable(since="0.1")
pub func addDelete(router: in Router, pattern: in String, handlerName: in String): Router
  requires: pattern.length > 0
  requires: handlerName.length > 0
{
  return addRoute(router, "DELETE", pattern, handlerName)
}

/// Register a PATCH route.
@stable(since="0.1")
pub func addPatch(router: in Router, pattern: in String, handlerName: in String): Router
  requires: pattern.length > 0
  requires: handlerName.length > 0
{
  return addRoute(router, "PATCH", pattern, handlerName)
}

/// Register a background worker that fires every `intervalMs` milliseconds.
/// `handlerName` must be the fully-qualified name of a function with signature
///   func(): Result[Unit, String]
/// The kernel starts the timer after the HTTP server begins accepting connections.
@stable(since="0.1")
pub func addWorker(router: in Router, name: in String, intervalMs: in Int, handlerName: in String): Router
  requires: name.length > 0
  requires: intervalMs > 0
  requires: handlerName.length > 0
{
  val w = WorkerRegistration(name = name, intervalMs = intervalMs, handlerName = handlerName)
  return Router(routes = router.routes, workers = router.workers + [w], pathPrefix = router.pathPrefix)
}

/// Scope all routes in `router` under `pathPrefix`.
/// Existing routes already have their prefix baked in; only future adds use the new prefix.
@stable(since="0.1")
pub func prefix(router: in Router, pathPrefix: in String): Router {
  return Router(routes = router.routes, workers = router.workers, pathPrefix = pathPrefix)
}

/// Merge two routers into one.  Routes and workers from both are included unchanged.
@stable(since="0.1")
pub func merge(a: in Router, b: in Router): Router {
  return Router(routes = a.routes + b.routes, workers = a.workers + b.workers, pathPrefix = "")
}

// ─── Runtime config ───────────────────────────────────────────────────────────

/// HTTP server binding and feature flags.
config Server {
  host:           String                = "0.0.0.0"
  port:           Int range 1..=65535  = 8080
  swaggerEnabled: Bool                  = false
  specPath:       String                = "/openapi.json"
}

/// CORS policy applied by the kernel HTTP middleware layer.
/// Applies to every response including 404 and OPTIONS preflight.
///
/// `allowedOrigins` defaults to the empty string — turning CORS on
/// without explicitly listing origins is rejected at startup (see
/// `start`).  `"*"` must never be paired with authenticated APIs
/// (it interacts badly with credentialed requests under CORS spec).
config Cors {
  enabled:        Bool   = false
  allowedOrigins: String = ""
  allowedMethods: String = "GET,POST,PUT,DELETE,OPTIONS,PATCH"
  allowedHeaders: String = "Content-Type,Authorization,Accept"
  maxAgeSeconds:  Int    = 86400
}

// ─── Server entry point ───────────────────────────────────────────────────────

/// Start the HTTP server with the given router.
/// Blocks until the process receives a shutdown signal.
/// Check the CORS configuration and return an error message if it is invalid,
/// or None if it is acceptable to proceed.  Exposed for testing; production
/// code goes through `start()` which panics on error.
@stable(since="0.1")
pub func corsConfigError(enabled: in Bool, allowedOrigins: in String): Option[String] {
  if enabled and allowedOrigins.length == 0 {
    Some(value =
      "Cors.enabled = true requires Cors.allowedOrigins to be a non-empty " +
      "comma-separated list of allowed origins. Set LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS " +
      "or the equivalent config source. \"*\" is accepted (with a startup warning) " +
      "but is unsafe for authenticated APIs (see RFC 6454 §3 and the CORS spec on " +
      "credentialed requests).")
  } else {
    None
  }
}

/// Binds to Server.host:Server.port (from env vars).
/// When Server.swaggerEnabled is true, also serves GET Server.specPath
/// (the live OpenAPI JSON spec) and GET /swagger (Swagger UI).
@stable(since="0.1")
pub func start(router: in Router): Unit {
  // Enabling CORS without an explicit origin list is a configuration
  // mistake — under the previous default of `"*"` this silently opened
  // a cross-origin backdoor (#353).  Fail closed at startup.
  match corsConfigError(Cors.enabled, Cors.allowedOrigins) {
    case Some(msg) -> panic(msg)
    case None      -> ()
  }
  // Explicit wildcard is permitted (some public, unauthenticated APIs
  // legitimately want it) but always emits a startup warning so the
  // operator sees it in logs.  Combined with credentialed requests
  // this opens the same backdoor the empty-default fix closes.
  if Cors.enabled and Cors.allowedOrigins == "*" {
    Std.Log.warn(
      "Cors.allowedOrigins = \"*\" is unsafe with authenticated APIs " +
      "(CORS spec disallows credentials + wildcard origin). " +
      "If this API is public and unauthenticated this is fine; " +
      "otherwise list explicit origins.")
  }
  HttpKernel.serve(
    Server.host,
    Server.port,
    Server.swaggerEnabled,
    Server.specPath,
    Cors.enabled,
    Cors.allowedOrigins,
    Cors.allowedMethods,
    Cors.allowedHeaders,
    Cors.maxAgeSeconds,
    router)
}
