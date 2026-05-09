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
///   LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS    — comma-separated origins or * (default: *)
///   LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS    — comma-separated HTTP methods
///   LYRIC_CONFIG_WEB_CORS_ALLOWEDHEADERS    — comma-separated header names
///   LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS     — preflight cache duration (default: 86400)

@runtime_checked
package Web

import Std.Core
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

/// A collection of routes.  Build one with create() then addGet/addPost/etc.
/// Compose multiple routers with merge() and scope them with prefix().
@stable(since="0.1")
pub record Router {
  routes:    [Route]
  pathPrefix: String
}

/// Empty router.
@stable(since="0.1")
pub func create(): Router {
  return Router(routes = [], pathPrefix = "")
}

// Private route-insertion helper.
func addRoute(router: in Router, method: in String, pattern: in String, handlerName: in String): Router {
  val full = router.pathPrefix + pattern
  val route = Route(method = method, pattern = full, handlerName = handlerName, summary = "", tags = [], deprecated = false)
  return Router(routes = router.routes + [route], pathPrefix = router.pathPrefix)
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

/// Scope all routes in `router` under `pathPrefix`.
/// Existing routes already have their prefix baked in; only future adds use the new prefix.
@stable(since="0.1")
pub func prefix(router: in Router, pathPrefix: in String): Router {
  return Router(routes = router.routes, pathPrefix = pathPrefix)
}

/// Merge two routers into one.  Routes from both are included unchanged.
@stable(since="0.1")
pub func merge(a: in Router, b: in Router): Router {
  return Router(routes = a.routes + b.routes, pathPrefix = "")
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
config Cors {
  enabled:        Bool   = false
  allowedOrigins: String = "*"
  allowedMethods: String = "GET,POST,PUT,DELETE,OPTIONS,PATCH"
  allowedHeaders: String = "Content-Type,Authorization,Accept"
  maxAgeSeconds:  Int    = 86400
}

// ─── Server entry point ───────────────────────────────────────────────────────

/// Start the HTTP server with the given router.
/// Blocks until the process receives a shutdown signal.
/// Binds to Server.host:Server.port (from env vars).
/// When Server.swaggerEnabled is true, also serves GET Server.specPath
/// (the live OpenAPI JSON spec) and GET /swagger (Swagger UI).
@stable(since="0.1")
pub func start(router: in Router): Unit {
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
