//! Web — HTTP server foundation, type vocabulary, and routing.
//! Stability: @experimental — the Router and ApiError vocabulary compile and
//! have unit tests, but the end-to-end pipeline (ASP.NET Core on .NET,
//! Undertow on JVM) has not been exercised against a live HTTP client in CI.
//!
//! Provides the ApiError type (with status-code constructor helpers),
//! the Router value type for building route tables, and the server
//! entry point.
//!
//! Route annotations (@get, @post, @put, @delete, @patch) are custom
//! annotations — apply them to handler functions and pass the handler's
//! qualified name to the router registration functions.  Discovery via
//! DLL reflection is planned once Lyric's annotation reflection ships.
//!
//! Workflow — code-first:
//!   1. Annotate handler functions with @get / @post / etc.
//!   2. Register routes explicitly with addGet / addPost / etc.
//!   3. Call Web.start(router) from main().
//!   4. Run `lyric web spec` to emit openapi.yaml from the compiled DLL.
//!
//! Workflow — spec-first:
//!   1. Run `lyric generate openapi spec.yaml` → stub .l files.
//!   2. Implement the generated handler bodies.
//!   3. Register and start as above.
//!
//! Runtime env vars (all read once at startup, fail-fast if invalid):
//!   LYRIC_CONFIG_WEB_SERVER_HOST            — bind address (default: 0.0.0.0)
//!   LYRIC_CONFIG_WEB_SERVER_PORT            — TCP port (default: 8080)
//!   LYRIC_CONFIG_WEB_SERVER_SWAGGERENABLED  — serve Swagger UI at /swagger (default: false)
//!   LYRIC_CONFIG_WEB_SERVER_SPECPATH        — OpenAPI spec URL path (default: /openapi.json)
//!   LYRIC_CONFIG_WEB_CORS_ENABLED           — enable CORS middleware (default: false)
//!   LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS    — comma-separated origins (no default; required when CORS enabled)
//!   LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS    — comma-separated HTTP methods
//!   LYRIC_CONFIG_WEB_CORS_ALLOWEDHEADERS    — comma-separated header names
//!   LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS     — preflight cache duration (default: 86400)
@runtime_checked
package Web

import Std.Core
import Std.Char
import Std.Console
import Std.Environment as Env
import Std.Iter
import Std.Parse

import extern System.IO.{ Stream }
import extern System.Net.{ HttpListener, HttpListenerContext, HttpListenerResponse, HttpListenerPrefixCollection }
import extern System.Text.{ Encoding }

func webJsonStr(s: in String): String {
  var r = "\""
  var i = 0
  while i < s.length {
    val code = toInt(s[i])
    if code == 34 {
      r = r + "\\\""
    } else if code == 92 {
      r = r + "\\\\"
    } else if code == 10 {
      r = r + "\\n"
    } else if code == 13 {
      r = r + "\\r"
    } else if code == 9 {
      r = r + "\\t"
    } else {
      r = r + s[i].toString()
    }
    i = i + 1
  }
  r + "\""
}

func webJsonArr(arr: in slice[String]): String {
  var r = "["
  var i = 0
  while i < arr.length {
    if i > 0 {
      r = r + ","
    }
    r = r + webJsonStr(arr[i])
    i = i + 1
  }
  r + "]"
}

func webJsonIntArr(arr: in slice[Int]): String {
  var r = "["
  var i = 0
  while i < arr.length {
    if i > 0 {
      r = r + ","
    }
    r = r + arr[i].toString()
    i = i + 1
  }
  r + "]"
}

func serve(
  host: in String,
  port: in Int,
  swaggerEnabled: in Bool,
  specPath: in String,
  corsEnabled: in Bool,
  corsOrigins: in String,
  corsMethods: in String,
  corsHeaders: in String,
  corsMaxAge: in Int,
  routeMethods: in slice[String],
  routePatterns: in slice[String],
  routeHandlers: in slice[String],
  routeSummaries: in slice[String],
  workerNames: in slice[String],
  workerIntervals: in slice[Int],
  workerHandlers: in slice[String],
): Unit
  requires: host.length > 0
  requires: port >= 1
  requires: port <= 65535
{
  val bindHost = if host == "0.0.0.0" or host == "+" or host == "*" { "+" } else { host }
  val prefix = "http://" + bindHost + ":" + port.toString() + "/"
  val swaggerStr = if swaggerEnabled { "true" } else { "false" }
  val corsStr = if corsEnabled { "true" } else { "false" }
  val payload = "{\"lyric-web\":\"phase-8-pathfinder\",\"host\":" + webJsonStr(host) + ",\"port\":" + port.toString() +
    ",\"swagger\":" +
    swaggerStr +
    ",\"specPath\":" +
    webJsonStr(specPath) +
    ",\"cors\":" +
    corsStr +
    ",\"routes\":{\"methods\":" +
    webJsonArr(routeMethods) +
    ",\"patterns\":" +
    webJsonArr(routePatterns) +
    ",\"handlers\":" +
    webJsonArr(routeHandlers) +
    ",\"summaries\":" +
    webJsonArr(routeSummaries) +
    "},\"workers\":{\"names\":" +
    webJsonArr(workerNames) +
    ",\"intervals\":" +
    webJsonIntArr(workerIntervals) +
    ",\"handlers\":" +
    webJsonArr(workerHandlers) +
    "}}"
  val listener = HttpListener.new()
  val prefs = listener.get_Prefixes()
  prefs.Add(prefix)
  try {
    listener.Start()
  } catch Bug as e {
    Console.error("[lyric-web] failed to start listening on " + prefix + ": " + e.message)
    listener.Close()
    Env.exitCode(1)
  }
  while true {
    try {
      val ctx = listener.GetContext()
      val resp = ctx.get_Response()
      resp.set_StatusCode(200)
      resp.set_ContentType("application/json")
      val utf8 = Encoding.get_UTF8()
      val bytes = utf8.GetBytes(payload)
      val stream = resp.get_OutputStream()
      stream.Write(bytes, 0, bytes.length)
      stream.Close()
    } catch Bug as e {
      // A caught Bug here means the request loop can no longer make progress
      // (e.g. the known cross-package codegen bug lyric-lang#5177). Surface
      // the failure loudly instead of exiting 0 as if the server had shut
      // down cleanly — a silent exit 0 looks like success to process
      // supervisors and masks the underlying defect from whoever is debugging it.
      Console.error("[lyric-web] request handling failed on " + prefix + ": " + e.message)
      listener.Close()
      Env.exitCode(1)
    }
  }
}

// ─── ApiError ─────────────────────────────────────────────────────────────────
/// HTTP API error.  Handlers return Result[T, ApiError] where the error
/// carries the HTTP status code alongside a human-readable message.
/// Use the constructor helpers below rather than building ApiError directly.
@stable(since = "0.1")
pub record ApiError {
  status: Int
  message: String
  detail: slice[String]
}

/// 400 Bad Request — malformed input, validation failure.
@stable(since = "0.1")
pub func badRequest(message: in String): ApiError {
  return ApiError(status = 400, message = message, detail = [])
}

/// 400 with per-field validation messages.
@stable(since = "0.1")
pub func badRequestWithDetail(message: in String, detail: in slice[String]): ApiError {
  return ApiError(status = 400, message = message, detail = detail)
}

/// 401 Unauthorized — missing or invalid credentials.
@stable(since = "0.1")
pub func unauthorized(message: in String): ApiError {
  return ApiError(status = 401, message = message, detail = [])
}

/// 403 Forbidden — credentials valid but caller lacks permission.
@stable(since = "0.1")
pub func forbidden(message: in String): ApiError {
  return ApiError(status = 403, message = message, detail = [])
}

/// 404 Not Found.
@stable(since = "0.1")
pub func notFound(message: in String): ApiError {
  return ApiError(status = 404, message = message, detail = [])
}

/// 409 Conflict — state collision (duplicate key, optimistic lock, etc.).
@stable(since = "0.1")
pub func conflict(message: in String): ApiError {
  return ApiError(status = 409, message = message, detail = [])
}

/// 422 Unprocessable Entity — well-formed request that fails domain rules.
@stable(since = "0.1")
pub func unprocessable(message: in String, detail: in slice[String]): ApiError {
  return ApiError(status = 422, message = message, detail = detail)
}

/// 429 Too Many Requests.
@stable(since = "0.1")
pub func tooManyRequests(message: in String): ApiError {
  return ApiError(status = 429, message = message, detail = [])
}

/// 500 Internal Server Error.
@stable(since = "0.1")
pub func internalError(message: in String): ApiError {
  return ApiError(status = 500, message = message, detail = [])
}

/// 503 Service Unavailable — upstream dependency unreachable or degraded.
@stable(since = "0.1")
pub func serviceUnavailable(message: in String): ApiError {
  return ApiError(status = 503, message = message, detail = [])
}

/// Arbitrary status code for cases not covered by the named constructors.
@stable(since = "0.1")
pub func apiError(status: in Int, message: in String): ApiError
  requires: status >= 100
  requires: status <= 599
{
  return ApiError(status = status, message = message, detail = [])
}

// ─── HTTP primitives ──────────────────────────────────────────────────────────
/// A single HTTP header name-value pair.
@stable(since = "0.1")
pub record Header {
  name: String
  value: String
  // ─── Router ───────────────────────────────────────────────────────────────────
}

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
@stable(since = "0.1")
pub record Route {
  method: String
  pattern: String
  handlerName: String
  // fully-qualified Lyric function name
  summary: String
  // optional: becomes the OpenAPI operationId summary
  tags: slice[String]
  // optional: OpenAPI tags for grouping
  deprecated: Bool
}

/// A background worker registered with the server.  The kernel starts one
/// timer per registration immediately after the HTTP server begins accepting
/// connections, and fires `handlerName` on the given interval until shutdown.
///
/// The handler must have the signature:
///   func myWorker(): Result[Unit, String]
/// where `Err(message)` causes the kernel to log the error and continue.
@stable(since = "0.1")
pub record WorkerRegistration {
  name: String
  // human-readable label used in logs and health output
  intervalMs: Int
  // poll interval in milliseconds
  handlerName: String
  // fully-qualified Lyric function name
}

/// A collection of routes and background workers.
/// Build one with create() then addGet/addPost/etc. and addWorker().
/// Compose multiple routers with merge() and scope them with prefix().
@stable(since = "0.1")
pub record Router {
  routes: slice[Route]
  workers: slice[WorkerRegistration]
  pathPrefix: String
}

/// Empty router.
@stable(since = "0.1")
pub func create(): Router {
  return Router(routes = [], workers = [], pathPrefix = "")
}

// Private route-insertion helper.
func addRoute(router: in Router, method: in String, pattern: in String, handlerName: in String): Router {
  val full = router.pathPrefix + pattern
  val route = Route(
    method = method,
    pattern = full,
    handlerName = handlerName,
    summary = "",
    tags = [],
    deprecated = false
  )
  return Router(routes = concat(router.routes, [route]), workers = router.workers, pathPrefix = router.pathPrefix)
}

/// Register a GET route.
@stable(since = "0.1")
pub func addGet(router: in Router, pattern: in String, handlerName: in String): Router
  requires: pattern.length > 0
  requires: handlerName.length > 0
{
  return addRoute(router, "GET", pattern, handlerName)
}

/// Register a POST route.
@stable(since = "0.1")
pub func addPost(router: in Router, pattern: in String, handlerName: in String): Router
  requires: pattern.length > 0
  requires: handlerName.length > 0
{
  return addRoute(router, "POST", pattern, handlerName)
}

/// Register a PUT route.
@stable(since = "0.1")
pub func addPut(router: in Router, pattern: in String, handlerName: in String): Router
  requires: pattern.length > 0
  requires: handlerName.length > 0
{
  return addRoute(router, "PUT", pattern, handlerName)
}

/// Register a DELETE route.
@stable(since = "0.1")
pub func addDelete(router: in Router, pattern: in String, handlerName: in String): Router
  requires: pattern.length > 0
  requires: handlerName.length > 0
{
  return addRoute(router, "DELETE", pattern, handlerName)
}

/// Register a PATCH route.
@stable(since = "0.1")
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
@stable(since = "0.1")
pub func addWorker(router: in Router, name: in String, intervalMs: in Int, handlerName: in String): Router
  requires: name.length > 0
  requires: intervalMs > 0
  requires: handlerName.length > 0
{
  val w = WorkerRegistration(name = name, intervalMs = intervalMs, handlerName = handlerName)
  return Router(routes = router.routes, workers = concat(router.workers, [w]), pathPrefix = router.pathPrefix)
}

/// Scope all routes in `router` under `pathPrefix`.
/// Existing routes already have their prefix baked in; only future adds use the new prefix.
@stable(since = "0.1")
pub func prefix(router: in Router, pathPrefix: in String): Router {
  return Router(routes = router.routes, workers = router.workers, pathPrefix = pathPrefix)
}

/// Merge two routers into one.  Routes and workers from both are included unchanged.
@stable(since = "0.1")
pub func merge(a: in Router, b: in Router): Router {
  return Router(routes = concat(a.routes, b.routes), workers = concat(a.workers, b.workers), pathPrefix = "")
}

// ─── CORS configuration guard ─────────────────────────────────────────────────
/// Validate the CORS configuration that `start()` reads from the environment.
/// Returns `Some(error)` when the configuration is unsafe to bind a server with,
/// `None` when it is acceptable.  Enabling CORS without an explicit origin list
/// is a fail-closed configuration mistake; a disabled CORS layer never errors,
/// and a wildcard origin (`*`) is accepted (the kernel warns rather than rejects).
/// `start()` calls this so the panic path and this pure helper share one rule.
@stable(since = "0.1")
pub func corsConfigError(enabled: in Bool, origins: in String): Option[String] {
  if enabled and origins.length == 0 {
    return Some(
      "LYRIC_CONFIG_WEB_CORS_ENABLED=true requires LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS " +
        "to be a non-empty comma-separated list of allowedOrigins."
    )
  }
  return None
}

/// Parse `LYRIC_CONFIG_WEB_SERVER_PORT` into a validated TCP port.
/// `Ok(port)` for a well-formed value in 1..=65535; `Err(message)` otherwise so
/// the caller can fail closed at startup.  Previously `start()` hardcoded 8080
/// and silently ignored this env var entirely (CWE-1188 / silent misconfig).
pub func parseServerPort(portStr: in String): Result[Int, String] {
  match tryParseInt(portStr) {
    case Ok(p) -> {
      if p >= 1 and p <= 65535 {
        return Ok(p)
      }
      return Err("LYRIC_CONFIG_WEB_SERVER_PORT must be in 1..=65535, got: " + portStr)
    }
    case Err(_) -> return Err("LYRIC_CONFIG_WEB_SERVER_PORT is not a valid integer: " + portStr)
  }
}

/// Parse `LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS`, falling back to `defaultValue`
/// for a malformed or negative value.  Previously `start()` hardcoded 86400
/// and ignored this env var.
pub func parseCorsMaxAge(maxAgeStr: in String, defaultValue: in Int): Int {
  match tryParseInt(maxAgeStr) {
    case Ok(m) -> if m >= 0 { m } else { defaultValue }
    case Err(_) -> defaultValue
  }
}

// ─── Server entry point ───────────────────────────────────────────────────────
/// Start the HTTP server with the given router.
/// Blocks until the process receives a shutdown signal.
/// Reads server and CORS configuration from environment variables at startup.
@stable(since = "0.1")
pub func start(router: in Router): Unit {
  val host = Env.getVarOrDefault("LYRIC_CONFIG_WEB_SERVER_HOST", "0.0.0.0")
  val portStr = Env.getVarOrDefault("LYRIC_CONFIG_WEB_SERVER_PORT", "8080")
  val swaggerStr = Env.getVarOrDefault("LYRIC_CONFIG_WEB_SERVER_SWAGGERENABLED", "false")
  val specPath = Env.getVarOrDefault("LYRIC_CONFIG_WEB_SERVER_SPECPATH", "/openapi.json")
  val corsEnabledStr = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_ENABLED", "false")
  val corsOrigins = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS", "")
  val corsMethods = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS", "GET,POST,PUT,DELETE,OPTIONS,PATCH")
  val corsHeaders = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_ALLOWEDHEADERS", "Content-Type,Authorization,Accept")
  val corsMaxAgeStr = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS", "86400")

  // Parse the configured port/CORS-max-age (previously hardcoded, ignoring the
  // documented env vars).  Fail closed on an invalid port.
  val port = match parseServerPort(portStr) { case Ok(p) -> p; case Err(e) -> panic(e) }
  val swaggerEnabled = swaggerStr == "true"
  val corsEnabled = corsEnabledStr == "true"
  val corsMaxAge = parseCorsMaxAge(corsMaxAgeStr, 86400)

  // Enabling CORS without an explicit origin list is a configuration
  // mistake.  Fail closed at startup.
  match corsConfigError(corsEnabled, corsOrigins) {
    case Some(err) -> panic(err)
    case None -> ()
  }

  // Unpack routes into parallel slices for the kernel boundary.
  var routeMethods: slice[String] = []
  var routePatterns: slice[String] = []
  var routeHandlers: slice[String] = []
  var routeSummaries: slice[String] = []
  var ri = 0
  while ri < router.routes.length {
    val r = router.routes[ri]
    val rm = r.method
    val rp = r.pattern
    val rh = r.handlerName
    val rs = r.summary
    routeMethods = concat(routeMethods, [rm])
    routePatterns = concat(routePatterns, [rp])
    routeHandlers = concat(routeHandlers, [rh])
    routeSummaries = concat(routeSummaries, [rs])
    ri = ri + 1
  }

  // Unpack workers into parallel slices for the kernel boundary.
  var workerNames: slice[String] = []
  var workerIntervals: slice[Int] = []
  var workerHandlers: slice[String] = []
  var wi = 0
  while wi < router.workers.length {
    val w = router.workers[wi]
    val wn = w.name
    val wm = w.intervalMs
    val wh = w.handlerName
    workerNames = concat(workerNames, [wn])
    workerIntervals = concat(workerIntervals, [wm])
    workerHandlers = concat(workerHandlers, [wh])
    wi = wi + 1
  }

  serve(
    host,
    port,
    swaggerEnabled,
    specPath,
    corsEnabled,
    corsOrigins,
    corsMethods,
    corsHeaders,
    corsMaxAge,
    routeMethods,
    routePatterns,
    routeHandlers,
    routeSummaries,
    workerNames,
    workerIntervals,
    workerHandlers
  )
}
