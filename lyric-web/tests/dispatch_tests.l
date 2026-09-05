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
import Std.Json
import Std.Testing
import Web
import Web.OpenApi as OpenApi

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
    case Some(trace) -> assertEqual(
      trace,
      "outer,inner,",
      "outer middleware's header wrap runs last (sees inner's result first)"
    )
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

// The reflected `Access-Control-Allow-Origin` must be paired with `Vary:
// Origin` so a shared/CDN cache keyed on URL can't serve one origin's response
// to another origin (cache poisoning).  Assert it on both the actual-response
// and the OPTIONS-preflight paths.
test "dispatch: CORS middleware sets Vary: Origin on the actual response" {
  var router = Web.create()
  router = Web.addGet(router, "/api", TextHandler(status = 200, body = "ok"))
  router = Web.withMiddleware(router, Web.corsMiddleware("https://example.com", "GET,POST", "Content-Type", 600))
  val resp = Web.dispatch(router, requestWithHeader("GET", "/api", "Origin", "https://example.com"))
  match mapGet(resp.headers, "Vary") {
    case Some(v) -> assertEqual(v, "Origin", "Vary must be Origin")
    case None -> assertTrue(false, "Vary: Origin must be present alongside a reflected ACAO")
  }
}

test "dispatch: CORS middleware sets Vary: Origin on the OPTIONS preflight" {
  var router = Web.create()
  router = Web.addGet(router, "/api", TextHandler(status = 200, body = "x"))
  router = Web.withMiddleware(router, Web.corsMiddleware("https://example.com", "GET,POST", "Content-Type", 600))
  val resp = Web.dispatch(router, requestWithHeader("OPTIONS", "/api", "Origin", "https://example.com"))
  match mapGet(resp.headers, "Vary") {
    case Some(v) -> assertEqual(v, "Origin", "preflight Vary must be Origin")
    case None -> assertTrue(false, "Vary: Origin must be present on the preflight response")
  }
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
  // Valid JSON is sent unmodified, byte-for-byte — no parse.
  val j = Web.json(200, "{\"a\":1}")
  assertEqualInt(j.status, 200, "json status")
  assertEqual(j.contentType, "application/json; charset=utf-8", "json content type")
  assertEqual(decodeUtf8(j.bodyBytes), "{\"a\":1}", "json body")

  // Malformed JSON is sent AS-IS — `json` never parses or re-interprets the
  // body, so a caller's malformed-JSON bug surfaces instead of being
  // silently masked as a quoted string (#5813 regression test).
  val jMalformed = Web.json(200, "{\"a\":1")
  assertEqual(decodeUtf8(jMalformed.bodyBytes), "{\"a\":1", "malformed json is sent unmodified, not re-escaped")

  // `jsonString` is the explicit helper for wrapping a raw (non-JSON) string
  // value, e.g. a bare UUID, as a JSON string.
  val jEscaped = Web.jsonString(201, "550e8400-e29b-41d4-a716-446655440000")
  assertEqualInt(jEscaped.status, 201, "jsonString status")
  assertEqual(jEscaped.contentType, "application/json; charset=utf-8", "jsonString content type")
  assertEqual(
    decodeUtf8(jEscaped.bodyBytes),
    "\"550e8400-e29b-41d4-a716-446655440000\"",
    "jsonString quotes and escapes the raw value"
  )

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

// #5360: `withSpec` attaches live `/openapi.json` and `/swagger` routes.
test "withSpec serves /openapi.json and /swagger, and existing routes still work" {
  var router = Web.create()
  router = Web.addGet(router, "/ping", TextHandler(status = 200, body = "pong"))
  val spec = OpenApi.newSpec("Demo API", "0.1.0", "")
  router = Web.withSpec(router, spec)

  val jsonResp = Web.dispatch(router, getRequest("/openapi.json"))
  assertEqualInt(jsonResp.status, 200, "/openapi.json status")
  assertEqual(jsonResp.contentType, "application/json; charset=utf-8", "/openapi.json content type")
  val jsonBody = decodeUtf8(jsonResp.bodyBytes)
  assertTrue(jsonBody.contains("\"openapi\":\"3.1.0\""), "/openapi.json body carries the openapi version")
  assertTrue(jsonBody.contains("\"title\":\"Demo API\""), "/openapi.json body carries the spec title")

  val uiResp = Web.dispatch(router, getRequest("/swagger"))
  assertEqualInt(uiResp.status, 200, "/swagger status")
  assertEqual(uiResp.contentType, "text/html; charset=utf-8", "/swagger content type")
  val uiBody = decodeUtf8(uiResp.bodyBytes)
  assertTrue(uiBody.contains("/openapi.json"), "/swagger page points at the JSON route")
  assertTrue(uiBody.contains("swagger-ui"), "/swagger page loads the Swagger UI bundle")

  // withSpec must not disturb routes registered before it.
  val pingResp = Web.dispatch(router, getRequest("/ping"))
  assertEqualInt(pingResp.status, 200, "pre-existing /ping route still dispatches")
}

test "withSpec scopes /openapi.json and /swagger under the router's pathPrefix" {
  var router = Web.prefix(Web.create(), "/api")
  val spec = OpenApi.newSpec("Demo API", "0.1.0", "")
  router = Web.withSpec(router, spec)

  val jsonResp = Web.dispatch(router, getRequest("/api/openapi.json"))
  assertEqualInt(jsonResp.status, 200, "/api/openapi.json status")

  val unprefixedResp = Web.dispatch(router, getRequest("/openapi.json"))
  assertEqualInt(unprefixedResp.status, 404, "the unprefixed path does not match")
}

// #5360 review follow-up: exercise every rendering branch `specToJson` has
// (schema `$ref` + inline forms, a parameter, a request body, a response,
// tags/summary/description, servers) — the earlier test above only covered
// an empty spec. Parses the rendered JSON back with `Std.Json` and reads
// the fields structurally rather than substring-matching, so a comma or
// quoting defect anywhere in the ~250 lines of per-type renderers would
// fail this test even if it happened to still "look like" JSON.
test "specToJson renders a fully-populated spec correctly" {
  var spec = OpenApi.newSpec("Full API", "2.0.0", "a full example")
  spec = OpenApi.addServer(spec, "https://api.example.com")
  spec = OpenApi.addSchema(spec, "Widget", OpenApi.scalarSchema(OpenApi.SchemaString, "", "a widget name"))

  val param = OpenApi.Parameter(
    name = "id",
    location = OpenApi.Query,
    required = true,
    description = "widget id",
    deprecated = false,
    schema = OpenApi.scalarSchema(OpenApi.SchemaInteger, "int32", "")
  )
  val resp = OpenApi.ApiResponse(
    statusCode = 200,
    description = "ok",
    content = [OpenApi.MediaType(contentType = "application/json", schema = OpenApi.refSchema("Widget"))]
  )
  val op = OpenApi.Operation(
    operationId = "getWidget",
    summary = "Get a widget",
    description = "",
    tags = ["widgets"],
    parameters = [param],
    requestBody = None,
    responses = [resp],
    deprecated = false
  )
  val pathItem = OpenApi.PathItem(
    pattern = "/widgets/{id}",
    get = Some(value = op),
    post = None,
    put = None,
    delete = None,
    patch = None,
    head = None,
    options = None
  )
  spec = OpenApi.addPath(spec, pathItem)

  val json = OpenApi.specToJson(spec)
  val doc = parseJson(json)
  val root = rootElement(doc)

  assertEqual(getString(getProperty(root, "openapi")), "3.1.0", "openapi version")
  val info = getProperty(root, "info")
  assertEqual(getString(getProperty(info, "title")), "Full API", "info.title")
  assertEqual(getString(getProperty(info, "version")), "2.0.0", "info.version")
  assertEqual(getString(getProperty(info, "description")), "a full example", "info.description")

  val serversCur = enumerateArray(getProperty(root, "servers"))
  var serversCur2 = serversCur
  assertTrue(arrayMoveNext(serversCur2), "servers has one entry")
  assertEqual(getString(getProperty(arrayCurrent(serversCur2), "url")), "https://api.example.com", "servers[0].url")

  val widgetSchema = getProperty(getProperty(getProperty(root, "components"), "schemas"), "Widget")
  assertEqual(getString(getProperty(widgetSchema, "type")), "string", "components.schemas.Widget.type")
  assertEqual(
    getString(getProperty(widgetSchema, "description")),
    "a widget name",
    "components.schemas.Widget.description"
  )

  val pathObj = getProperty(getProperty(root, "paths"), "/widgets/{id}")
  val getOp = getProperty(pathObj, "get")
  assertEqual(getString(getProperty(getOp, "operationId")), "getWidget", "paths./widgets/{id}.get.operationId")
  assertEqual(getString(getProperty(getOp, "summary")), "Get a widget", "paths./widgets/{id}.get.summary")

  var tagsCur = enumerateArray(getProperty(getOp, "tags"))
  assertTrue(arrayMoveNext(tagsCur), "get.tags has one entry")
  assertEqual(getString(arrayCurrent(tagsCur)), "widgets", "get.tags[0]")

  var paramsCur = enumerateArray(getProperty(getOp, "parameters"))
  assertTrue(arrayMoveNext(paramsCur), "get.parameters has one entry")
  val paramObj = arrayCurrent(paramsCur)
  assertEqual(getString(getProperty(paramObj, "name")), "id", "parameters[0].name")
  assertEqual(getString(getProperty(paramObj, "in")), "query", "parameters[0].in")
  assertTrue(getBoolean(getProperty(paramObj, "required")), "parameters[0].required")
  assertEqual(getString(getProperty(getProperty(paramObj, "schema"), "type")), "integer", "parameters[0].schema.type")
  assertEqual(getString(getProperty(getProperty(paramObj, "schema"), "format")), "int32", "parameters[0].schema.format")

  val responseObj = getProperty(getProperty(getOp, "responses"), "200")
  assertEqual(getString(getProperty(responseObj, "description")), "ok", "responses.200.description")
  val responseSchema = getProperty(getProperty(getProperty(responseObj, "content"), "application/json"), "schema")
  assertEqual(getString(getProperty(responseSchema, "$ref")), "#/components/schemas/Widget", "responses.200 $ref")

  disposeJson(doc)
}
