//! tests/dispatch_tests.l — end-to-end regression tests for `Web.dispatch`,
//! the pure routing/middleware core `Web.serve` is a thin I/O shell around.
//!
//! Before this test file (and the accompanying fix to `Web.serve`), a
//! request against a running `lyric-web` server got the same hardcoded
//! JSON payload regardless of method or path — `serve()` never matched
//! `routePatterns` against the incoming request at all. These tests
//! exercise the fix directly (method/path matching, path-param
//! extraction, wildcard static routes, middleware composition, CORS,
//! and static file serving with path-traversal rejection) without
//! starting a real HTTP listener — see `examples/rest_service.l`'s CI
//! smoke test (`.github/workflows/ci.yml`) for the live-socket
//! end-to-end proof.
//!
//! Handlers here are small records implementing `Web.Handler` rather than
//! closures — see `Web.Handler`'s doc comment (issue #5363): invoking a
//! closure from a package other than the one that defined it is unreliable
//! in the current self-hosted MSIL backend once 2+ packages each define
//! their own closures, which is exactly this test module's relationship to
//! `Web` (a separate package importing it).
@test_module
package Web.DispatchTests

import Std.Core
import Std.Collections
import Std.Environment
import Std.File
import Std.Testing
import Web

// Explicit @externTarget bindings rather than auto-FFI-resolved
// `Encoding.get_UTF8().GetString(bytes)` call syntax — see web.l's
// `utf8Encoding`/`encodingGetBytes` comment (issue #5361's neighboring
// finding: auto-FFI-resolved instance-method calls on a plain
// `import extern`-declared type do not reliably resolve at runtime once
// the calling package is linked as a restored dependency, which is how
// `lyric test` links this test module against `Web`).
extern type Encoding = "System.Text.Encoding"

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func encodingGetString(e: in Encoding, bytes: in slice[Byte]): String = ()

func decodeUtf8(bytes: in slice[Byte]): String {
  return encodingGetString(utf8Encoding(), bytes)
}

func emptyParams(): Map[String, String] {
  val m: Map[String, String] = newMap()
  m
}

func getRequest(path: in String): Web.Request {
  Web.Request(
    method = "GET",
    path = path,
    pathParams = emptyParams(),
    queryParams = emptyParams(),
    headers = emptyParams(),
    body = ""
  )
}

func requestWithHeader(method: in String, path: in String, headerName: in String, headerValue: in String): Web.Request {
  val headers: Map[String, String] = newMap()
  headers[headerName.toLower()] = headerValue
  Web.Request(
    method = method,
    path = path,
    pathParams = emptyParams(),
    queryParams = emptyParams(),
    headers = headers,
    body = ""
  )
}

func requestWithQuery(path: in String, query: in Map[String, String]): Web.Request {
  Web.Request(
    method = "GET",
    path = path,
    pathParams = emptyParams(),
    queryParams = query,
    headers = emptyParams(),
    body = ""
  )
}

func scratchDir(label: in String): String {
  val base = Environment.getVarOrDefault("TMPDIR", "/tmp")
  base + "/lyric_web_dispatch_tests_" + label
}

// ─── Test handlers ────────────────────────────────────────────────────────────
/// A fixed-response handler, for tests where the handler's own logic isn't
/// what's under test.
record TextHandler {
  status: Int
  body: String
}

impl Web.Handler for TextHandler {
  func handle(req: in Web.Request): Web.Response {
    Web.text(self.status, self.body)
  }
}

record UserIdHandler {
}

impl Web.Handler for UserIdHandler {
  func handle(req: in Web.Request): Web.Response {
    match Web.pathParam(req, "id") {
      case Some(id) -> Web.text(200, "user:" + id)
      case None -> Web.text(500, "missing id")
    }
  }
}

record OrgRepoHandler {
}

impl Web.Handler for OrgRepoHandler {
  func handle(req: in Web.Request): Web.Response {
    val org = match Web.pathParam(req, "org") { case Some(v) -> v; case None -> "" }
    val repo = match Web.pathParam(req, "repo") { case Some(v) -> v; case None -> "" }
    Web.text(200, org + "/" + repo)
  }
}

record PathParamEchoHandler {
  paramName: String
}

impl Web.Handler for PathParamEchoHandler {
  func handle(req: in Web.Request): Web.Response {
    match Web.pathParam(req, self.paramName) {
      case Some(v) -> Web.text(200, v)
      case None -> Web.text(500, "")
    }
  }
}

record QueryParamEchoHandler {
  paramName: String
}

impl Web.Handler for QueryParamEchoHandler {
  func handle(req: in Web.Request): Web.Response {
    match Web.queryParam(req, self.paramName) {
      case Some(q) -> Web.text(200, q)
      case None -> Web.text(400, "missing " + self.paramName)
    }
  }
}

record HeaderEchoHandler {
  headerName: String
}

impl Web.Handler for HeaderEchoHandler {
  func handle(req: in Web.Request): Web.Response {
    match Web.header(req, self.headerName) {
      case Some(v) -> Web.text(200, v)
      case None -> Web.text(401, "no " + self.headerName)
    }
  }
}

// ─── Basic method + path dispatch ────────────────────────────────────────────
test "dispatch: GET route matches and invokes the handler" {
  var router = Web.create()
  router = Web.addGet(router, "/hello", TextHandler(status = 200, body = "hi"))
  val resp = Web.dispatch(router, getRequest("/hello"))
  assertEqualInt(resp.status, 200, "matched GET route returns the handler's status")
  assertEqual(decodeUtf8(resp.bodyBytes), "hi", "matched GET route returns the handler's body")
}

test "dispatch: unmatched path returns 404" {
  var router = Web.create()
  router = Web.addGet(router, "/hello", TextHandler(status = 200, body = "hi"))
  val resp = Web.dispatch(router, getRequest("/nope"))
  assertEqualInt(resp.status, 404, "unmatched path falls through to a 404")
}

test "dispatch: method mismatch on an otherwise-matching path returns 404" {
  var router = Web.create()
  router = Web.addGet(router, "/hello", TextHandler(status = 200, body = "hi"))
  val postReq = Web.Request(
    method = "POST",
    path = "/hello",
    pathParams = emptyParams(),
    queryParams = emptyParams(),
    headers = emptyParams(),
    body = ""
  )
  val resp = Web.dispatch(router, postReq)
  assertEqualInt(resp.status, 404, "GET-only route does not answer POST")
}

test "dispatch: two routes on the same path, different methods, both work" {
  var router = Web.create()
  router = Web.addGet(router, "/things", TextHandler(status = 200, body = "list"))
  router = Web.addPost(router, "/things", TextHandler(status = 201, body = "created"))
  val getResp = Web.dispatch(router, getRequest("/things"))
  val postReq = Web.Request(
    method = "POST",
    path = "/things",
    pathParams = emptyParams(),
    queryParams = emptyParams(),
    headers = emptyParams(),
    body = ""
  )
  val postResp = Web.dispatch(router, postReq)
  assertEqualInt(getResp.status, 200, "GET /things")
  assertEqual(decodeUtf8(getResp.bodyBytes), "list", "GET body")
  assertEqualInt(postResp.status, 201, "POST /things")
  assertEqual(decodeUtf8(postResp.bodyBytes), "created", "POST body")
}

// ─── Path parameters ──────────────────────────────────────────────────────────
test "dispatch: {id} path segment is captured into pathParams" {
  var router = Web.create()
  router = Web.addGet(router, "/users/{id}", UserIdHandler())
  val resp = Web.dispatch(router, getRequest("/users/42"))
  assertEqualInt(resp.status, 200, "route matched")
  assertEqual(decodeUtf8(resp.bodyBytes), "user:42", "id captured from the path")
}

test "dispatch: multiple path params in one pattern" {
  var router = Web.create()
  router = Web.addGet(router, "/orgs/{org}/repos/{repo}", OrgRepoHandler())
  val resp = Web.dispatch(router, getRequest("/orgs/nichobbs/repos/lyric-lang"))
  assertEqual(decodeUtf8(resp.bodyBytes), "nichobbs/lyric-lang", "both segments captured")
}

test "dispatch: a literal segment does not match a differing literal" {
  var router = Web.create()
  router = Web.addGet(router, "/users/{id}/profile", TextHandler(status = 200, body = "profile"))
  val resp = Web.dispatch(router, getRequest("/users/42/settings"))
  assertEqualInt(resp.status, 404, "trailing literal segment must match exactly")
}

test "dispatch: percent-encoded path segment is decoded before capture" {
  var router = Web.create()
  router = Web.addGet(router, "/search/{term}", PathParamEchoHandler(paramName = "term"))
  val resp = Web.dispatch(router, getRequest("/search/a%20b"))
  assertEqual(decodeUtf8(resp.bodyBytes), "a b", "percent-encoded space is decoded")
}

test "dispatch: {*rest} wildcard captures the remaining path including slashes" {
  var router = Web.create()
  router = Web.addGet(router, "/files/{*rest}", PathParamEchoHandler(paramName = "rest"))
  val resp = Web.dispatch(router, getRequest("/files/a/b/c.txt"))
  assertEqual(decodeUtf8(resp.bodyBytes), "a/b/c.txt", "wildcard captures every remaining segment")
}

// ─── Query parameters ─────────────────────────────────────────────────────────
test "dispatch: queryParams are available to the handler" {
  var router = Web.create()
  router = Web.addGet(router, "/search", QueryParamEchoHandler(paramName = "q"))
  val query: Map[String, String] = newMap()
  query["q"] = "lyric lang"
  val resp = Web.dispatch(router, requestWithQuery("/search", query))
  assertEqual(decodeUtf8(resp.bodyBytes), "lyric lang", "query param reaches the handler")
}

// ─── Headers ──────────────────────────────────────────────────────────────────
test "dispatch: header lookup is case-insensitive" {
  var router = Web.create()
  router = Web.addGet(router, "/whoami", HeaderEchoHandler(headerName = "x-api-key"))
  val resp = Web.dispatch(router, requestWithHeader("GET", "/whoami", "X-Api-Key", "secret123"))
  assertEqual(decodeUtf8(resp.bodyBytes), "secret123", "header found regardless of registered case")
}

// ─── Middleware composition ───────────────────────────────────────────────────
record MarkerMiddleware {
  tag: String
}

impl Web.Middleware for MarkerMiddleware {
  func wrap(req: in Web.Request, next: Web.Handler): Web.Response {
    val h = next
    val resp = h.handle(req)
    val marked = Web.withResponseHeader(resp, "X-Trace", self.tag + "," + traceSoFar(resp))
    marked
  }
}

func traceSoFar(resp: in Web.Response): String {
  match mapGet(resp.headers, "X-Trace") {
    case Some(v) -> v
    case None -> ""
  }
}

test "dispatch: middleware runs outermost-first around the route handler" {
  var router = Web.create()
  router = Web.addGet(router, "/traced", TextHandler(status = 200, body = "ok"))
  router = Web.withMiddleware(router, MarkerMiddleware(tag = "outer"))
  router = Web.withMiddleware(router, MarkerMiddleware(tag = "inner"))
  val resp = Web.dispatch(router, getRequest("/traced"))
  match mapGet(resp.headers, "X-Trace") {
    case Some(trace) -> assertEqual(trace, "outer,inner,", "outer middleware's header wrap runs last (sees inner's result first)")
    case None -> assertTrue(false, "X-Trace header must be present")
  }
}

record BlockAllMiddleware {
}

impl Web.Middleware for BlockAllMiddleware {
  func wrap(req: in Web.Request, next: Web.Handler): Web.Response {
    Web.errorResponse(Web.forbidden("blocked"))
  }
}

test "dispatch: a middleware can short-circuit before the route handler runs" {
  var router = Web.create()
  router = Web.addGet(router, "/guarded", TextHandler(status = 200, body = "should not run"))
  router = Web.withMiddleware(router, BlockAllMiddleware())
  val resp = Web.dispatch(router, getRequest("/guarded"))
  assertEqualInt(resp.status, 403, "the middleware's short-circuit response wins, the handler never runs")
}

// ─── CORS middleware ──────────────────────────────────────────────────────────
test "dispatch: CORS middleware adds Access-Control-Allow-Origin for an allowed origin" {
  var router = Web.create()
  router = Web.addGet(router, "/api", TextHandler(status = 200, body = "ok"))
  router = Web.withMiddleware(router, Web.corsMiddleware("https://example.com", "GET,POST", "Content-Type", 600))
  val resp = Web.dispatch(router, requestWithHeader("GET", "/api", "Origin", "https://example.com"))
  match mapGet(resp.headers, "Access-Control-Allow-Origin") {
    case Some(v) -> assertEqual(v, "https://example.com", "allowed origin is echoed back")
    case None -> assertTrue(false, "CORS header must be present for an allowed origin")
  }
}

test "dispatch: CORS middleware does not add headers for a disallowed origin" {
  var router = Web.create()
  router = Web.addGet(router, "/api", TextHandler(status = 200, body = "ok"))
  router = Web.withMiddleware(
    router,
    Web.corsMiddleware("https://allowed.example.com", "GET,POST", "Content-Type", 600)
  )
  val resp = Web.dispatch(router, requestWithHeader("GET", "/api", "Origin", "https://evil.example.com"))
  match mapGet(resp.headers, "Access-Control-Allow-Origin") {
    case Some(_) -> assertTrue(false, "disallowed origin must not get a CORS header")
    case None -> ()
  }
  assertEqualInt(resp.status, 200, "the request itself still reaches the handler")
}

test "dispatch: CORS middleware answers an OPTIONS preflight without reaching the handler" {
  var router = Web.create()
  router = Web.addGet(router, "/api", TextHandler(status = 200, body = "should not run"))
  router = Web.withMiddleware(router, Web.corsMiddleware("https://example.com", "GET,POST", "Content-Type", 600))
  val preflight = requestWithHeader("OPTIONS", "/api", "Origin", "https://example.com")
  val resp = Web.dispatch(router, preflight)
  assertEqualInt(resp.status, 204, "preflight answered directly with 204")
  match mapGet(resp.headers, "Access-Control-Allow-Methods") {
    case Some(v) -> assertEqual(v, "GET,POST", "preflight reports the configured methods")
    case None -> assertTrue(false, "Access-Control-Allow-Methods must be present")
  }
}

// ─── Static file serving ──────────────────────────────────────────────────────
test "dispatch: static file middleware serves an existing file" {
  val dir = scratchDir("static_basic")
  val _ = createDir(dir)
  val _ = writeText(dir + "/hello.txt", "static hello")

  var router = Web.create()
  router = Web.withStaticFiles(
    router,
    Web.StaticFiles(root = dir, mountPrefix = "", cacheControlSeconds = 60, fallbackToIndex = false)
  )
  router = Web.addGet(router, "/api-only", TextHandler(status = 200, body = "api"))

  val resp = Web.dispatch(router, getRequest("/hello.txt"))
  assertEqualInt(resp.status, 200, "existing static file is served")
  assertEqual(decodeUtf8(resp.bodyBytes), "static hello", "file content is served verbatim")
  assertEqual(resp.contentType, "text/plain; charset=utf-8", "content type is inferred from the extension")
}

test "dispatch: static file middleware falls through to routes when no file matches" {
  val dir = scratchDir("static_fallthrough")
  val _ = createDir(dir)

  var router = Web.create()
  router = Web.withStaticFiles(
    router,
    Web.StaticFiles(root = dir, mountPrefix = "", cacheControlSeconds = 60, fallbackToIndex = false)
  )
  router = Web.addGet(router, "/api-only", TextHandler(status = 200, body = "api"))

  val resp = Web.dispatch(router, getRequest("/api-only"))
  assertEqualInt(resp.status, 200, "no matching file: falls through to the route")
  assertEqual(decodeUtf8(resp.bodyBytes), "api", "route handler ran")
}

test "dispatch: static file middleware respects a mount prefix" {
  val dir = scratchDir("static_mount")
  val _ = createDir(dir)
  val _ = writeText(dir + "/app.css", "body{color:red}")

  var router = Web.create()
  router = Web.withStaticFiles(
    router,
    Web.StaticFiles(root = dir, mountPrefix = "/assets", cacheControlSeconds = 60, fallbackToIndex = false)
  )

  val hit = Web.dispatch(router, getRequest("/assets/app.css"))
  assertEqualInt(hit.status, 200, "file under the mount prefix is served")
  assertEqual(hit.contentType, "text/css; charset=utf-8", "css content type inferred")

  val miss = Web.dispatch(router, getRequest("/app.css"))
  assertEqualInt(miss.status, 404, "the same file outside the mount prefix is not served")
}

test "dispatch: static file middleware rejects path traversal outside root" {
  val dir = scratchDir("static_traversal")
  val _ = createDir(dir + "/public")
  val _ = writeText(dir + "/secret.txt", "top secret")
  val _ = writeText(dir + "/public/ok.txt", "fine to serve")

  var router = Web.create()
  router = Web.withStaticFiles(
    router,
    Web.StaticFiles(
      root = dir + "/public",
      mountPrefix = "",
      cacheControlSeconds = 60,
      fallbackToIndex = false
    )
  )

  val traversal = Web.dispatch(router, getRequest("/../secret.txt"))
  assertEqualInt(traversal.status, 404, "a traversal attempt never reaches the file outside root")

  val legit = Web.dispatch(router, getRequest("/ok.txt"))
  assertEqualInt(legit.status, 200, "a legitimate file inside root is still served")
  assertEqual(decodeUtf8(legit.bodyBytes), "fine to serve", "the in-root file content is correct")
}

test "dispatch: fallbackToIndex serves index.html for an unmatched static path" {
  val dir = scratchDir("static_fallback_index")
  val _ = createDir(dir)
  val _ = writeText(dir + "/index.html", "<h1>home</h1>")

  var router = Web.create()
  router = Web.withStaticFiles(
    router,
    Web.StaticFiles(root = dir, mountPrefix = "", cacheControlSeconds = 60, fallbackToIndex = true)
  )

  val resp = Web.dispatch(router, getRequest("/some/spa/route"))
  assertEqualInt(resp.status, 200, "SPA fallback serves index.html")
  assertEqual(decodeUtf8(resp.bodyBytes), "<h1>home</h1>", "index.html content served")
}

// ─── Response helper constructors ─────────────────────────────────────────────
test "json/text/html/noContent/errorResponse construct the expected status and content type" {
  val j = Web.json(200, "{\"a\":1}")
  assertEqualInt(j.status, 200, "json status")
  assertEqual(j.contentType, "application/json; charset=utf-8", "json content type")
  assertEqual(decodeUtf8(j.bodyBytes), "{\"a\":1}", "json body")

  val t = Web.text(201, "created")
  assertEqualInt(t.status, 201, "text status")
  assertEqual(t.contentType, "text/plain; charset=utf-8", "text content type")

  val h = Web.html(200, "<p>hi</p>")
  assertEqual(h.contentType, "text/html; charset=utf-8", "html content type")

  val nc = Web.noContent()
  assertEqualInt(nc.status, 204, "noContent status")
  assertEqualInt(nc.bodyBytes.length, 0, "noContent has an empty body")

  val err = Web.errorResponse(Web.notFound("nope"))
  assertEqualInt(err.status, 404, "errorResponse carries the ApiError's status")
  assertTrue(decodeUtf8(err.bodyBytes).contains("nope"), "errorResponse body carries the message")
}

test "withResponseHeader replaces an existing value rather than duplicating it" {
  var resp = Web.text(200, "ok")
  resp = Web.withResponseHeader(resp, "X-Custom", "first")
  resp = Web.withResponseHeader(resp, "X-Custom", "second")
  match mapGet(resp.headers, "X-Custom") {
    case Some(v) -> assertEqual(v, "second", "second write wins, no duplicate entries")
    case None -> assertTrue(false, "header must be present")
  }
}
