//! Web — HTTP server, routing, static files, and a middleware pipeline.
//!
//! Route handlers implement the `Handler` interface (`func handle(req):
//! Response`) — no runtime reflection, no name-based lookup. `Handler` and
//! `Middleware` are interfaces rather than stored closures/function values
//! deliberately: invoking a closure defined in one package from another
//! package that also defines its own closures is unreliable in the current
//! self-hosted MSIL backend, up to and including silent wrong-value
//! corruption with no exception at all (issue #5363) — the same reason
//! every other pluggable-behavior abstraction in this codebase (`WsHandler`,
//! `MailSender`, `StorageBucket`, …) is an interface rather than a stored
//! closure. (An earlier revision of this module stored `handlerName:
//! String` for a DLL-reflection dispatcher that was never implemented and
//! is planned never to be — see D099, `docs/03-decision-log.md`, for why
//! reflection-based dispatch was rejected outright.)
//!
//! Route annotations (@get, @post, @put, @delete, @patch) remain custom
//! annotations for OpenAPI code generation; they do not affect dispatch.
//!
//! Workflow:
//!   1. Write a handler: a zero-field record implementing `Handler`
//!      (helpers: `Web.json`, `Web.text`, `Web.html`, `Web.errorResponse`).
//!      Read path/query/header values with `Web.pathParam` / `Web.queryParam`
//!      / `Web.header`.  To protect a handler with a `Web.Aspects` template,
//!      keep your protected business logic in its own function (the aspect
//!      matches by name against parameters like `authToken: in String`, per
//!      the aspect's row constraint) and call it from `handle`'s body — see
//!      `lyric-web/README.md` for a worked example.
//!   2. Register routes with addGet / addPost / addPut / addDelete / addPatch.
//!   3. Optionally attach a static file mount (`Web.withStaticFiles`) and/or
//!      middleware (`Web.withMiddleware`) — see `Web.StaticFiles`,
//!      `Web.Middleware` below, and `docs/58-wire-templates-sketch.md` for
//!      composing multiple mounts/middleware via `contributes[Middleware]`.
//!   4. Call `Web.start(router)` from main().
//!   5. Run `lyric web spec` to emit openapi.yaml from the compiled DLL.
//!
//! `Web.dispatch(router, request): Response` is the pure routing core
//! (method + path matching, path-param extraction, middleware
//! composition) with no I/O — `Web.serve`/`Web.start` are a thin
//! `Std.HttpServer` shell around it, and `dispatch` itself is what the
//! test suite exercises directly.
//!
//! Runtime env vars (all read once at startup, fail-fast if invalid):
//!   LYRIC_CONFIG_WEB_SERVER_HOST            — bind address (default: 0.0.0.0)
//!   LYRIC_CONFIG_WEB_SERVER_PORT            — TCP port (default: 8080)
//!   LYRIC_CONFIG_WEB_CORS_ENABLED           — enable CORS middleware (default: false)
//!   LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS    — comma-separated origins (no default; required when CORS enabled)
//!   LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS    — comma-separated HTTP methods
//!   LYRIC_CONFIG_WEB_CORS_ALLOWEDHEADERS    — comma-separated header names
//!   LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS     — preflight cache duration (default: 86400)
//!
//! Not yet implemented (tracked separately, not silently no-op'd):
//!   - Live OpenAPI/Swagger UI serving (issue #5360) — use `lyric web spec`
//!     to generate the spec at build time instead.
//!   - `Web.addWorker` background timers are registered but not yet fired
//!     (issue #5359) — the obvious implementation (structured-concurrency
//!     `spawn`) is a synchronous no-op on `--target dotnet` today.
@runtime_checked
package Web

import Std.Core
import Std.Char
import Std.Console
import Std.Environment as Env
import Std.Parse
import Std.Collections
import Std.String
import Std.HttpServer
import Std.File
import Web.Kernel.Runtime as HttpKernel

@externTarget("System.IO.Path.GetFullPath")
func pathGetFullPath(path: in String): String = ()

// Explicit @externTarget bindings rather than auto-FFI-resolved
// `Encoding.get_UTF8().GetBytes(s)` call syntax: the auto-FFI resolution
// path for a plain `import extern`-declared type's instance methods does
// not reliably resolve at runtime once `Web` is consumed as a restored
// (already-compiled) dependency from another project — see issue #5361's
// neighboring finding. Explicit bindings (matching `Std.HttpServer`'s
// kernel) are unaffected.
extern type Encoding = "System.Text.Encoding"

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func encodingGetBytes(e: in Encoding, s: in String): slice[Byte] = ()

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

// ─── ApiError ─────────────────────────────────────────────────────────────────
/// HTTP API error.  Handlers protected by a `Web.Aspects` template (or that
/// need a typed error) return `Result[T, ApiError]`; convert to a `Response`
/// with `errorResponse` on the `Err` branch.  Use the constructor helpers
/// below rather than building ApiError directly.
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

func apiErrorJson(err: in ApiError): String {
  return "{\"message\":" + webJsonStr(err.message) + ",\"detail\":" + webJsonArr(err.detail) + "}"
}

// ─── Request ──────────────────────────────────────────────────────────────────
/// An incoming HTTP request.  `pathParams` holds values captured from
/// `{name}` / `{*name}` pattern segments; `queryParams` and `headers` are
/// parsed from the request unconditionally (empty maps if absent).
/// Header lookups are case-insensitive (keys are stored lower-cased).
@stable(since = "0.2")
pub record Request {
  method: String
  path: String
  pathParams: Map[String, String]
  queryParams: Map[String, String]
  headers: Map[String, String]
  body: String
}

/// Look up a captured path-pattern parameter by name.
@stable(since = "0.2")
pub func pathParam(req: in Request, name: in String): Option[String] {
  return mapGet(req.pathParams, name)
}

/// Look up a query-string parameter by name.
@stable(since = "0.2")
pub func queryParam(req: in Request, name: in String): Option[String] {
  return mapGet(req.queryParams, name)
}

/// Look up a request header by name (case-insensitive).
@stable(since = "0.2")
pub func header(req: in Request, name: in String): Option[String] {
  return mapGet(req.headers, name.toLower())
}

// ─── Response ─────────────────────────────────────────────────────────────────
/// An outgoing HTTP response.  Build one with `json` / `text` / `html` /
/// `bytesResponse` / `noContent` / `errorResponse`, and add headers with
/// `withResponseHeader`.
@stable(since = "0.2")
pub record Response {
  status: Int
  contentType: String
  bodyBytes: slice[Byte]
  headers: Map[String, String]
}

func utf8Encode(s: in String): slice[Byte] {
  return encodingGetBytes(utf8Encoding(), s)
}

/// A `application/json; charset=utf-8` response with the given raw JSON body.
@stable(since = "0.2")
pub func json(status: in Int, body: in String): Response {
  val empty: Map[String, String] = newMap()
  return Response(
    status = status,
    contentType = "application/json; charset=utf-8",
    bodyBytes = utf8Encode(body),
    headers = empty
  )
}

/// A `text/plain; charset=utf-8` response.
@stable(since = "0.2")
pub func text(status: in Int, body: in String): Response {
  val empty: Map[String, String] = newMap()
  return Response(
    status = status,
    contentType = "text/plain; charset=utf-8",
    bodyBytes = utf8Encode(body),
    headers = empty
  )
}

/// A `text/html; charset=utf-8` response.
@stable(since = "0.2")
pub func html(status: in Int, body: in String): Response {
  val empty: Map[String, String] = newMap()
  return Response(
    status = status,
    contentType = "text/html; charset=utf-8",
    bodyBytes = utf8Encode(body),
    headers = empty
  )
}

/// A response with a raw byte body and an explicit content type
/// (static files, images, binary downloads).
@stable(since = "0.2")
pub func bytesResponse(status: in Int, contentType: in String, body: in slice[Byte]): Response {
  val empty: Map[String, String] = newMap()
  return Response(status = status, contentType = contentType, bodyBytes = body, headers = empty)
}

/// A 204 No Content response.
@stable(since = "0.2")
pub func noContent(): Response {
  val empty: Map[String, String] = newMap()
  val noBytes: slice[Byte] = []
  return Response(status = 204, contentType = "", bodyBytes = noBytes, headers = empty)
}

/// Convert an `ApiError` into a JSON response carrying its status code.
@stable(since = "0.2")
pub func errorResponse(err: in ApiError): Response {
  return json(err.status, apiErrorJson(err))
}

/// Return a copy of `resp` with header `name` set to `value` (replacing
/// any existing value for that name).
@stable(since = "0.2")
pub func withResponseHeader(resp: in Response, name: in String, value: in String): Response {
  val h: Map[String, String] = newMap()
  mapPutAll(h, resp.headers)
  h[name] = value
  return Response(status = resp.status, contentType = resp.contentType, bodyBytes = resp.bodyBytes, headers = h)
}

// ─── Handler / Middleware ───────────────────────────────────────────────────────
/// The canonical route-handler and middleware-continuation contract.
/// An interface rather than a stored closure/function value deliberately:
/// invoking a closure defined in one package from another package that also
/// defines its own closures is unreliable in the current self-hosted MSIL
/// backend (silent wrong-value corruption in the worst case — see issue
/// #5363), the same reason every other pluggable-behavior abstraction in
/// this codebase (`WsHandler`, `MailSender`, `StorageBucket`, …) is an
/// interface rather than a stored closure. Implement it with a small
/// zero-field record: `impl Handler for MyHandler { func handle(req) {...} }`.
@stable(since = "0.2")
pub interface Handler {
  func handle(req: in Request): Response
}

/// A middleware wraps the handler chain: inspect/rewrite the request,
/// optionally short-circuit, or run `next.handle(req)` and inspect/rewrite
/// the response. Register with `Web.withMiddleware` — order is
/// outermost-first, matching `contributes[Middleware]` ordering
/// (`docs/58-wire-templates-sketch.md`).
@stable(since = "0.2")
pub interface Middleware {
  func wrap(req: in Request, next: Handler): Response
}

// ─── Router ───────────────────────────────────────────────────────────────────
/// A single registered route binding a method + URL pattern to a handler.
///
/// Path parameters are embedded in the pattern as `{name}` segments,
/// captured into `Request.pathParams` under `name`.  A final `{*name}`
/// segment captures the rest of the path (including any further `/`) —
/// useful for nested static-file trees.
@stable(since = "0.2")
pub record Route {
  method: String
  pattern: String
  handler: Handler
  summary: String
  // optional: becomes the OpenAPI operationId summary
  tags: slice[String]
  // optional: OpenAPI tags for grouping
  deprecated: Bool
}

/// A background worker registered with the server.  **Not yet dispatched**
/// (issue #5359) — registered workers are not currently invoked.
@stable(since = "0.1")
pub record WorkerRegistration {
  name: String
  intervalMs: Int
  handlerName: String
}

/// A collection of routes, background workers, and middleware.
/// Build one with create() then addGet/addPost/etc., addWorker(),
/// withMiddleware(), and withStaticFiles().  Compose multiple routers
/// with merge() and scope them with prefix().
@stable(since = "0.2")
pub record Router {
  routes: slice[Route]
  workers: slice[WorkerRegistration]
  middlewares: slice[Middleware]
  pathPrefix: String
}

/// Empty router.
@stable(since = "0.2")
pub func create(): Router {
  val noRoutes: slice[Route] = []
  val noWorkers: slice[WorkerRegistration] = []
  val noMiddleware: slice[Middleware] = []
  return Router(routes = noRoutes, workers = noWorkers, middlewares = noMiddleware, pathPrefix = "")
}

// Private route-insertion helper.
func addRoute(router: in Router, method: in String, pattern: in String, handler: in Handler): Router {
  val full = router.pathPrefix + pattern
  val route = Route(method = method, pattern = full, handler = handler, summary = "", tags = [], deprecated = false)
  return Router(
    routes = concat(router.routes, [route]),
    workers = router.workers,
    middlewares = router.middlewares,
    pathPrefix = router.pathPrefix
  )
}

/// Register a GET route.
@stable(since = "0.2")
pub func addGet(router: in Router, pattern: in String, handler: in Handler): Router
  requires: pattern.length > 0
{
  return addRoute(router, "GET", pattern, handler)
}

/// Register a POST route.
@stable(since = "0.2")
pub func addPost(router: in Router, pattern: in String, handler: in Handler): Router
  requires: pattern.length > 0
{
  return addRoute(router, "POST", pattern, handler)
}

/// Register a PUT route.
@stable(since = "0.2")
pub func addPut(router: in Router, pattern: in String, handler: in Handler): Router
  requires: pattern.length > 0
{
  return addRoute(router, "PUT", pattern, handler)
}

/// Register a DELETE route.
@stable(since = "0.2")
pub func addDelete(router: in Router, pattern: in String, handler: in Handler): Router
  requires: pattern.length > 0
{
  return addRoute(router, "DELETE", pattern, handler)
}

/// Register a PATCH route.
@stable(since = "0.2")
pub func addPatch(router: in Router, pattern: in String, handler: in Handler): Router
  requires: pattern.length > 0
{
  return addRoute(router, "PATCH", pattern, handler)
}

/// Register a background worker.  **Not yet dispatched** — see
/// `WorkerRegistration` and issue #5359.
@stable(since = "0.1")
pub func addWorker(router: in Router, name: in String, intervalMs: in Int, handlerName: in String): Router
  requires: name.length > 0
  requires: intervalMs > 0
  requires: handlerName.length > 0
{
  val w = WorkerRegistration(name = name, intervalMs = intervalMs, handlerName = handlerName)
  return Router(
    routes = router.routes,
    workers = concat(router.workers, [w]),
    middlewares = router.middlewares,
    pathPrefix = router.pathPrefix
  )
}

/// Append a middleware to the pipeline.  Middleware runs outermost-first
/// in registration order: the first middleware registered sees the
/// request first and the response last.
@stable(since = "0.2")
pub func withMiddleware(router: in Router, mw: in Middleware): Router {
  return Router(
    routes = router.routes,
    workers = router.workers,
    middlewares = concat(router.middlewares, [mw]),
    pathPrefix = router.pathPrefix
  )
}

/// Scope all routes in `router` under `pathPrefix`.
/// Existing routes already have their prefix baked in; only future adds use the new prefix.
@stable(since = "0.2")
pub func prefix(router: in Router, pathPrefix: in String): Router {
  return Router(
    routes = router.routes,
    workers = router.workers,
    middlewares = router.middlewares,
    pathPrefix = pathPrefix
  )
}

/// Merge two routers into one.  Routes, workers, and middleware from both
/// are included unchanged, template-router first.
@stable(since = "0.2")
pub func merge(a: in Router, b: in Router): Router {
  return Router(
    routes = concat(a.routes, b.routes),
    workers = concat(a.workers, b.workers),
    middlewares = concat(a.middlewares, b.middlewares),
    pathPrefix = ""
  )
}

// ─── Static file serving ────────────────────────────────────────────────────────
/// Library-contributed config template for a static file mount
/// (`docs/58-wire-templates-sketch.md` §3).  Instantiate directly with
/// `withStaticFiles`, or in a `wire` graph with
/// `config Assets from Web.StaticFiles { root: String = "./wwwroot" }`.
/// Mount several roots at different prefixes by calling `withStaticFiles`
/// (or contributing several `Middleware` entries) more than once — e.g.
/// `mountPrefix = "/assets"` for one root and `mountPrefix = "/uploads"`
/// for another.
@stable(since = "0.2")
pub config StaticFiles {
  root: String = "./public"
  mountPrefix: String = ""
  cacheControlSeconds: Int = 3600
  fallbackToIndex: Bool = false
}

// Path traversal guard, in two layers:
//   1. Reject a null byte outright (a classic string-truncation attack
//      against the underlying file APIs).
//   2. The authoritative check: resolve `candidate` to its canonical
//      absolute path via `Path.GetFullPath` (which collapses `..` and
//      `.` segments) and require it to fall *within* the canonically
//      resolved `root` — not a substring match on the raw request path,
//      which could be fooled by an encoding this layer doesn't happen to
//      normalise. This defeats any `..`/backslash/encoding variant,
//      because it inspects the resolved filesystem path, not the
//      original string.
func withinRoot(root: in String, candidate: in String): Bool {
  val fullRoot = pathGetFullPath(root)
  val fullCandidate = pathGetFullPath(candidate)
  return fullCandidate == fullRoot or fullCandidate.startsWith(fullRoot + "/")
}

func resolveStaticFile(cfg: in StaticFiles, relative: in String): Option[String] {
  if relative.contains("\u{0000}") {
    return None
  }
  val cleaned = if relative.startsWith("/") { relative.substring(1) } else { relative }
  val candidate = if cleaned.length == 0 { cfg.root + "/index.html" } else { cfg.root + "/" + cleaned }
  if withinRoot(cfg.root, candidate) and fileExists(candidate) {
    return Some(candidate)
  }
  if cfg.fallbackToIndex {
    val indexPath = cfg.root + "/index.html"
    if fileExists(indexPath) {
      return Some(indexPath)
    }
  }
  return None
}

func contentTypeForPath(path: in String): String {
  val lower = path.toLower()
  if lower.endsWith(".html") or lower.endsWith(".htm") {
    return "text/html; charset=utf-8"
  } else if lower.endsWith(".css") {
    return "text/css; charset=utf-8"
  } else if lower.endsWith(".js") or lower.endsWith(".mjs") {
    return "text/javascript; charset=utf-8"
  } else if lower.endsWith(".json") {
    return "application/json; charset=utf-8"
  } else if lower.endsWith(".svg") {
    return "image/svg+xml"
  } else if lower.endsWith(".png") {
    return "image/png"
  } else if lower.endsWith(".jpg") or lower.endsWith(".jpeg") {
    return "image/jpeg"
  } else if lower.endsWith(".gif") {
    return "image/gif"
  } else if lower.endsWith(".webp") {
    return "image/webp"
  } else if lower.endsWith(".ico") {
    return "image/x-icon"
  } else if lower.endsWith(".woff2") {
    return "font/woff2"
  } else if lower.endsWith(".woff") {
    return "font/woff"
  } else if lower.endsWith(".wasm") {
    return "application/wasm"
  } else if lower.endsWith(".txt") {
    return "text/plain; charset=utf-8"
  } else if lower.endsWith(".xml") {
    return "application/xml; charset=utf-8"
  } else if lower.endsWith(".pdf") {
    return "application/pdf"
  }
  return "application/octet-stream"
}

record StaticFileMiddleware {
  cfg: StaticFiles
}

impl Middleware for StaticFileMiddleware {
  func wrap(req: in Request, next: Handler): Response {
    val h = next
    if req.method != "GET" and req.method != "HEAD" {
      return h.handle(req)
    }
    val mount = self.cfg.mountPrefix
    if mount.length > 0 and not req.path.startsWith(mount) {
      return h.handle(req)
    }
    val relative = if mount.length > 0 { req.path.substring(mount.length) } else { req.path }
    match resolveStaticFile(self.cfg, relative) {
      case Some(resolvedMatch) -> {
        val resolved: String = resolvedMatch
        match readBytes(resolved) {
          case Ok(fileBytes) -> {
            val bytes: List[Byte] = fileBytes
            val resp = bytesResponse(200, contentTypeForPath(resolved), bytes.toArray())
            return withResponseHeader(resp, "Cache-Control", "public, max-age=" + self.cfg.cacheControlSeconds.toString())
          }
          case Err(_) -> return h.handle(req)
        }
      }
      case None -> return h.handle(req)
    }
  }
}

/// Serve static files from `cfg.root` under `cfg.mountPrefix` (or the
/// whole path if `mountPrefix` is empty).  A request that doesn't map to
/// an existing file falls through to the rest of the pipeline (routes,
/// then 404) — mount static files before or after your API routes freely.
@stable(since = "0.2")
pub func staticFiles(cfg: in StaticFiles): Middleware {
  return StaticFileMiddleware(cfg = cfg)
}

/// Sugar for `withMiddleware(router, staticFiles(cfg))`.
@stable(since = "0.2")
pub func withStaticFiles(router: in Router, cfg: in StaticFiles): Router {
  return withMiddleware(router, staticFiles(cfg))
}

// ─── CORS middleware ────────────────────────────────────────────────────────────
func corsOriginAllowed(configured: in String, origin: in String): Bool {
  if configured == "*" {
    return true
  }
  val candidates = configured.split(",")
  var i = 0
  while i < candidates.length {
    if candidates[i].trim() == origin {
      return true
    }
    i = i + 1
  }
  return false
}

record CorsMiddleware {
  allowedOrigins: String
  allowedMethods: String
  allowedHeaders: String
  maxAgeSeconds: Int
}

impl Middleware for CorsMiddleware {
  func wrap(req: in Request, next: Handler): Response {
    val h = next
    val originOpt = header(req, "Origin")
    val origin = match originOpt { case Some(o) -> o; case None -> "" }
    if origin.length == 0 or not corsOriginAllowed(self.allowedOrigins, origin) {
      return h.handle(req)
    }
    if req.method == "OPTIONS" {
      var resp = noContent()
      resp = withResponseHeader(resp, "Access-Control-Allow-Origin", origin)
      resp = withResponseHeader(resp, "Access-Control-Allow-Methods", self.allowedMethods)
      resp = withResponseHeader(resp, "Access-Control-Allow-Headers", self.allowedHeaders)
      resp = withResponseHeader(resp, "Access-Control-Max-Age", self.maxAgeSeconds.toString())
      return resp
    }
    val resp = h.handle(req)
    return withResponseHeader(resp, "Access-Control-Allow-Origin", origin)
  }
}

/// Build a CORS middleware.  `Web.start` attaches one automatically from
/// the `LYRIC_CONFIG_WEB_CORS_*` env vars when CORS is enabled; call this
/// directly if you build your own middleware pipeline instead of using
/// `Web.start`.
@stable(since = "0.2")
pub func corsMiddleware(
  allowedOrigins: in String,
  allowedMethods: in String,
  allowedHeaders: in String,
  maxAgeSeconds: in Int,
): Middleware {
  return CorsMiddleware(
    allowedOrigins = allowedOrigins,
    allowedMethods = allowedMethods,
    allowedHeaders = allowedHeaders,
    maxAgeSeconds = maxAgeSeconds
  )
}

// ─── Request logging middleware ─────────────────────────────────────────────────
record LoggingMiddleware {
}

impl Middleware for LoggingMiddleware {
  func wrap(req: in Request, next: Handler): Response {
    val h = next
    val resp = h.handle(req)
    Console.println(req.method + " " + req.path + " -> " + resp.status.toString())
    return resp
  }
}

/// A middleware that logs `METHOD path -> status` for every request. Not
/// attached by default; add with `withMiddleware(router, requestLogger())`.
@stable(since = "0.2")
pub func requestLogger(): Middleware {
  return LoggingMiddleware()
}

// ─── Path pattern matching ───────────────────────────────────────────────────────
func normalizedSegments(path: in String): slice[String] {
  var p = path
  if p.startsWith("/") {
    p = p.substring(1)
  }
  if p.length > 0 and p.endsWith("/") {
    p = p.substring(0, p.length - 1)
  }
  if p.length == 0 {
    val none: slice[String] = []
    return none
  }
  return p.split("/")
}

func matchSegments(patternSegs: in slice[String], pathSegs: in slice[String]): Option[Map[String, String]] {
  val params: Map[String, String] = newMap()
  var pi = 0
  var ai = 0
  while pi < patternSegs.length {
    val seg = patternSegs[pi]
    if seg.startsWith("{*") and seg.endsWith("}") {
      val name = seg.substring(2, seg.length - 3)
      var rest = ""
      var j = ai
      while j < pathSegs.length {
        if j > ai {
          rest = rest + "/"
        }
        rest = rest + pathSegs[j]
        j = j + 1
      }
      params[name] = urlDecode(rest)
      return Some(params)
    } else if seg.startsWith("{") and seg.endsWith("}") {
      if ai >= pathSegs.length {
        return None
      }
      val name = seg.substring(1, seg.length - 2)
      params[name] = urlDecode(pathSegs[ai])
      pi = pi + 1
      ai = ai + 1
    } else {
      if ai >= pathSegs.length {
        return None
      }
      if seg != urlDecode(pathSegs[ai]) {
        return None
      }
      pi = pi + 1
      ai = ai + 1
    }
  }
  if ai != pathSegs.length {
    return None
  }
  return Some(params)
}

func matchPattern(pattern: in String, path: in String): Option[Map[String, String]] {
  return matchSegments(normalizedSegments(pattern), normalizedSegments(path))
}

// A key/value pair parsed from one `&`-separated query-string segment.
// Returned by value (never received as an in-place-mutated Map parameter):
// mutating a Map passed in as a parameter, from inside a nested match arm,
// has produced CLR-level miscompiles (InvalidProgramException) in this
// backend — see issue #5363's neighboring finding. Every Map mutation in
// this file is therefore kept in the same function that owns the Map as a
// local, never delegated to a helper that receives the Map as a parameter.
record QueryPair {
  key: String
  value: String
}

func parseQueryPair(pair: in String): Option[QueryPair] {
  if pair.length == 0 {
    return None
  }
  match pair.indexOf("=") {
    case Some(eq) -> {
      // Copy the match-bound `eq` into a fresh local before using it as a
      // call argument: passing a match-pattern-bound variable straight into
      // a call from inside its own arm has produced CLR-level miscompiles
      // (InvalidProgramException) in this backend (issue #5363's
      // neighboring finding) — copying it first is a confirmed-safe
      // workaround.
      val splitAt: Int = eq
      val key = urlDecode(pair.substring(0, splitAt).replace("+", " "))
      val value = urlDecode(pair.substring(splitAt + 1).replace("+", " "))
      Some(QueryPair(key = key, value = value))
    }
    case None -> {
      Some(QueryPair(key = urlDecode(pair.replace("+", " ")), value = ""))
    }
  }
}

/// Parse a raw (no leading `?`) query string into a `name -> value` map,
/// URL-decoding both.  Exposed so a JVM-target kernel can build the same
/// `Request.queryParams` shape as the dotnet accept loop's `buildRequest`
/// without duplicating URL-decoding logic (`Web.Kernel.Runtime`'s Undertow
/// handler calls this directly).
@stable(since = "0.2")
pub func parseQueryString(raw: in String): Map[String, String] {
  val result: Map[String, String] = newMap()
  if raw.length == 0 {
    return result
  }
  val pairs = raw.split("&")
  var i = 0
  while i < pairs.length {
    match parseQueryPair(pairs[i]) {
      case Some(kv) -> {
        val k: String = kv.key
        val v: String = kv.value
        result[k] = v
      }
      case None -> ()
    }
    i = i + 1
  }
  return result
}

// ─── Dispatch (pure — no I/O) ────────────────────────────────────────────────────
func routeDispatch(routes: in slice[Route], req: in Request): Response {
  var i = 0
  while i < routes.length {
    val route = routes[i]
    if route.method == req.method {
      match matchPattern(route.pattern, req.path) {
        case Some(params) -> {
          val bound = Request(
            method = req.method,
            path = req.path,
            pathParams = params,
            queryParams = req.queryParams,
            headers = req.headers,
            body = req.body
          )
          val h = route.handler
          return h.handle(bound)
        }
        case None -> ()
      }
    }
    i = i + 1
  }
  return errorResponse(notFound("no route for " + req.method + " " + req.path))
}

// The route-matching tail of the middleware chain, as a Handler value —
// see MiddlewareChain's doc comment for why this is a record rather than a
// closure.
record RouteDispatchHandler {
  routes: slice[Route]
}

impl Handler for RouteDispatchHandler {
  func handle(req: in Request): Response {
    routeDispatch(self.routes, req)
  }
}

/// A `Handler` representing "run `mws[idx..]` then `inner`" — deliberately a
/// record implementing `Handler` rather than a composed closure chain:
/// closures defined in one package invoked from another package that also
/// defines closures are unreliable in the current self-hosted MSIL backend
/// (issue #5363); `Middleware`/`Handler` are interfaces for the same reason
/// (see `Handler`'s doc comment). `idx` counts UP from 0 so `mws[0]` (the
/// first-registered middleware) ends up as the outermost wrapper — it must
/// be the first to see the request and the last to see the response, per
/// `withMiddleware`'s documented order.
record MiddlewareChain {
  mws: slice[Middleware]
  idx: Int
  inner: Handler
}

impl Handler for MiddlewareChain {
  func handle(req: in Request): Response {
    if self.idx >= self.mws.length {
      val h = self.inner
      return h.handle(req)
    }
    val mw = self.mws[self.idx]
    val next: Handler = MiddlewareChain(mws = self.mws, idx = self.idx + 1, inner = self.inner)
    return mw.wrap(req, next)
  }
}

/// Route (and, if configured, middleware-wrap) `req` through `router` and
/// return the `Response` — no I/O.  This is what `Web.serve` calls per
/// request, and what tests exercise directly without starting a real
/// HTTP listener.
@stable(since = "0.2")
pub func dispatch(router: in Router, req: in Request): Response {
  val inner: Handler = RouteDispatchHandler(routes = router.routes)
  val chain: Handler = MiddlewareChain(mws = router.middlewares, idx = 0, inner = inner)
  return chain.handle(req)
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
/// the caller can fail closed at startup.
@stable(since = "0.1")
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
/// for a malformed or negative value.
@stable(since = "0.1")
pub func parseCorsMaxAge(maxAgeStr: in String, defaultValue: in Int): Int {
  match tryParseInt(maxAgeStr) {
    case Ok(m) -> if m >= 0 { m } else { defaultValue }
    case Err(_) -> defaultValue
  }
}

// ─── Server entry point ───────────────────────────────────────────────────────
// The four helpers below and the dotnet serve() implementation call
// Std.HttpServer symbols (requestQuery/requestHeaders/respondBytesWithHeaders)
// that only the dotnet kernel (`_kernel/http_server.l`) exposes — the JVM
// kernel (`_kernel_jvm/http_server.l`) is a narrower bootstrap-grade surface
// (see its header comment), so Web binds `io.undertow` directly on jvm
// instead (Web.Kernel.Runtime, below).  All five items are therefore
// dotnet-only; erased for jvm builds by Lyric.Cfg before type-checking, so
// the absent Std.HttpServer symbols never surface as an unknown-name error.
@cfg(feature = "dotnet")
func headerValueOr(rawHeaders: in Map[String, String], name: in String, fallback: in String): String {
  match mapGet(rawHeaders, name) {
    case Some(value) -> return value
    case None -> return fallback
  }
}

@cfg(feature = "dotnet")
func normalizeHeaders(rawHeaders: in Map[String, String]): Map[String, String] {
  val headers: Map[String, String] = newMap()
  val rawNames = mapKeys(rawHeaders).toArray()
  var hi = 0
  while hi < rawNames.length {
    val name = rawNames[hi]
    val value = headerValueOr(rawHeaders, name, "")
    headers[name.toLower()] = value
    hi = hi + 1
  }
  return headers
}

@cfg(feature = "dotnet")
func buildRequest(ctx: in HttpContext): Request {
  val method = requestMethod(ctx).toUpper()
  val path = requestPath(ctx)
  val queryParams = parseQueryString(requestQuery(ctx))
  val headers = normalizeHeaders(requestHeaders(ctx))
  val body = if method == "GET" or method == "HEAD" { "" } else { requestBody(ctx) }
  val noParams: Map[String, String] = newMap()
  return Request(
    method = method,
    path = path,
    pathParams = noParams,
    queryParams = queryParams,
    headers = headers,
    body = body
  )
}

@cfg(feature = "dotnet")
func writeResponse(ctx: in HttpContext, resp: in Response): Unit {
  val contentType = if resp.contentType.length == 0 { "text/plain" } else { resp.contentType }
  respondBytesWithHeaders(ctx, resp.status, contentType, resp.bodyBytes, resp.headers)
}

/// Run the accept loop for `router` on `host`:`port`.  Blocks forever
/// (single-threaded, synchronous — one request handled at a time).
/// Prefer `Web.start(router)` unless you need to bind without reading
/// the environment (e.g. attaching a router built by `Lambda.withRouter`
/// through a different entry point).
///
/// dotnet: a hand-rolled Std.HttpServer (System.Net.HttpListener) accept
/// loop — single-threaded, synchronous (see README "Known gaps").
@stable(since = "0.2")
@cfg(feature = "dotnet")
pub func serve(router: in Router, host: in String, port: in Int): Unit
  requires: host.length > 0
  requires: port >= 1
  requires: port <= 65535
{
  val bindHost = if host == "0.0.0.0" or host == "+" or host == "*" { "+" } else { host }
  val prefixStr = "http://" + bindHost + ":" + port.toString() + "/"
  val listener = startListener(prefixStr)
  Console.println("[lyric-web] Listening on " + prefixStr)
  while true {
    try {
      val ctx = nextContext(listener)
      val req = buildRequest(ctx)
      val resp = dispatch(router, req)
      writeResponse(ctx, resp)
    } catch Bug as e {
      // A caught Bug here means the request loop can no longer make progress.
      // Surface the failure loudly instead of exiting 0 as if the server had
      // shut down cleanly — a silent exit 0 looks like success to process
      // supervisors and masks the underlying defect from whoever is debugging it.
      Console.error("[lyric-web] request handling failed on " + prefixStr + ": " + e.message)
      stopListener(listener)
      Env.exitCode(1)
    }
  }
}

/// jvm: delegates entirely to Web.Kernel.Runtime's Undertow-backed server —
/// see that package for the dispatch model.  Undertow's own XNIO I/O/worker
/// threads handle concurrent requests, unlike the dotnet accept loop above.
@stable(since = "0.2")
@cfg(feature = "jvm")
pub func serve(router: in Router, host: in String, port: in Int): Unit
  requires: host.length > 0
  requires: port >= 1
  requires: port <= 65535
{
  HttpKernel.serve(host, port, router)
}

/// Start the HTTP server with the given router.
/// Blocks until the process receives a shutdown signal.
/// Reads server and CORS configuration from environment variables at startup.
@stable(since = "0.1")
pub func start(router: in Router): Unit {
  val host = Env.getVarOrDefault("LYRIC_CONFIG_WEB_SERVER_HOST", "0.0.0.0")
  val portStr = Env.getVarOrDefault("LYRIC_CONFIG_WEB_SERVER_PORT", "8080")
  val corsEnabledStr = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_ENABLED", "false")
  val corsOrigins = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_ALLOWEDORIGINS", "")
  val corsMethods = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_ALLOWEDMETHODS", "GET,POST,PUT,DELETE,OPTIONS,PATCH")
  val corsHeaders = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_ALLOWEDHEADERS", "Content-Type,Authorization,Accept")
  val corsMaxAgeStr = Env.getVarOrDefault("LYRIC_CONFIG_WEB_CORS_MAXAGESECONDS", "86400")

  // Parse the configured port/CORS-max-age (previously hardcoded, ignoring the
  // documented env vars).  Fail closed on an invalid port.
  val port = match parseServerPort(portStr) { case Ok(p) -> p; case Err(e) -> panic(e) }
  val corsEnabled = corsEnabledStr == "true"
  val corsMaxAge = parseCorsMaxAge(corsMaxAgeStr, 86400)

  // Enabling CORS without an explicit origin list is a configuration
  // mistake.  Fail closed at startup.
  match corsConfigError(corsEnabled, corsOrigins) {
    case Some(err) -> panic(err)
    case None -> ()
  }

  val routerWithCors = if corsEnabled {
    withMiddleware(router, corsMiddleware(corsOrigins, corsMethods, corsHeaders, corsMaxAge))
  } else {
    router
  }

  serve(routerWithCors, host, port)
}
