//! Search — search engine integration for Lyric applications.
//! Stability: @experimental — the API compiles and the Elasticsearch and
//! Meilisearch backends are implemented over real HTTP + JSON (issue #5408),
//! but neither has been driven against a live cluster in CI (no Elasticsearch
//! or Meilisearch server is available in this repository's CI sandbox).
//!
//! Provides a `SearchClient` interface with Elasticsearch and Meilisearch
//! backends selectable at runtime via feature flags.  Both backends expose
//! the same API: index, batch-index, search, suggest, delete, and index
//! management.
//!
//! Neither backend binds a native SDK (`Elastic.Clients.Elasticsearch` /
//! `com.meilisearch.sdk`, etc.) — both engines speak plain HTTP + JSON, so
//! the implementation is pure Lyric over `Std.Http` / `Std.Json`. It is
//! built directly on `Std.Http` rather than the higher-level `Std.Rest`:
//! `Std.Rest`'s `RestClient` verbs throw `System.MissingMethodException`
//! at runtime (a pre-existing `Std.Http`/`Std.Rest` cross-package
//! free-async-function defect, documented in detail in
//! `lyric-lambda/src/dispatch.l`'s header and confirmed independently
//! here — see `HttpConfig`'s doc comment below). See README.md "Platform
//! parity" for why the earlier `extern package` native-SDK approach was
//! abandoned (issues #5067, #5324, #5408).
//!
//! Typical usage:
//!
//!   import Search
//!   import Std.Collections
//!
//!   // Connect (backend selected by compile-time feature flag):
//!   match await Search.connect("elasticsearch") {
//!     case Ok(client) ->
//!       val doc = Search.makeDoc("products", "p-1", Map.of("name", "Widget"))
//!       await Search.index(client, doc)
//!
//!       val q = Search.makeQuery("products", "Widget")
//!       match await Search.search(client, q) {
//!         case Ok(result) -> ...
//!         case Err(e)     -> ...
//!       }
//!     case Err(e) -> ...
//!   }
//!
//! Runtime config env vars, read by `Search.connect`:
//!   LYRIC_SEARCH_ELASTICSEARCH_URL         — Elasticsearch base URL (required)
//!   LYRIC_SEARCH_ELASTICSEARCH_USERNAME    — HTTP basic auth username (default: "")
//!   LYRIC_SEARCH_ELASTICSEARCH_PASSWORD    — HTTP basic auth password (default: "")
//!   LYRIC_SEARCH_ELASTICSEARCH_TIMEOUT_MS  — request timeout ms (default: 30000)
//!   LYRIC_SEARCH_MEILISEARCH_URL           — Meilisearch base URL (required)
//!   LYRIC_SEARCH_MEILISEARCH_API_KEY       — Meilisearch API key (default: "")
//!   LYRIC_SEARCH_MEILISEARCH_TIMEOUT_MS    — request timeout ms (default: 30000)
//! `connectElasticsearch` / `connectMeilisearch` accept these values explicitly
//! instead, for callers that don't want env-var-driven configuration.
@runtime_checked
package Search

import Std.Core
import Std.Collections
import Std.Json
import Std.Errors
import Std.Http
import Std.Char
import Std.Encoding
import Std.Environment
import Std.Parse

// ─── Error type ───────────────────────────────────────────────────────────────
/// Error returned by SearchClient operations.
@stable(since = "0.1")
pub record SearchError {
  message: String
  code: String
  statusCode: Int
}

// ─── Document model ───────────────────────────────────────────────────────────
/// A document to be indexed.  Field values are strings; callers should
/// JSON-encode complex values before storing them.
@stable(since = "0.1")
pub record SearchDocument {
  id: String
  index: String
  fields: Map[String, String]
}

// ─── Result model ─────────────────────────────────────────────────────────────
/// A highlighted fragment for a single field.
@stable(since = "0.1")
pub record Highlight {
  field: String
  fragments: slice[String]
}

/// A single search hit.
@stable(since = "0.1")
pub record SearchHit {
  id: String
  index: String
  score: Double
  highlights: slice[Highlight]
  source: Map[String, String]
}

/// Sorting specification for a single field.
@stable(since = "0.1")
pub record SortField {
  field: String
  descending: Bool
}

/// A filter clause applied to search queries.
/// `operator` is one of: "eq", "gt", "gte", "lt", "lte", "contains".
@stable(since = "0.1")
pub record SearchFilter {
  field: String
  value: String
  operator: String
}

/// A full search request.
@stable(since = "0.1")
pub record SearchQuery {
  index: String
  query: String
  filters: slice[SearchFilter]
  from: Int
  size: Int
  sort: slice[SortField]
  highlightFields: slice[String]
}

/// The result of a search operation.
@stable(since = "0.1")
pub record SearchResult {
  total: Long
  hits: slice[SearchHit]
  tookMs: Int
  scrollId: Option[String]
}

/// Autocomplete / type-ahead suggestions.
@stable(since = "0.1")
pub record SuggestResult {
  suggestions: slice[String]
  tookMs: Int
}

/// Result of an index or upsert operation.  `status` is "created" or
/// "updated" for Elasticsearch (its `_doc` API reports which occurred).
/// Meilisearch's document API is asynchronous (task-queue based); this
/// client waits briefly for the enqueued task to finish and reports
/// "created" on success or "enqueued" if it did not finish within the
/// wait budget — see `meilisearch_backend.l`'s `msAwaitTask`.
@stable(since = "0.1")
pub record IndexResult {
  id: String
  version: Long
  status: String   // "created", "updated", "enqueued", or "noop"
}

// ─── Client interface ─────────────────────────────────────────────────────────
/// Search engine client.  Obtain via `Search.connectElasticsearch()`,
/// `Search.connectMeilisearch()`, or the dispatching `Search.connect()`.
///
/// Every method is `async` because every implementation performs a real
/// HTTP round trip — there is no synchronous, in-process fast path.
@stable(since = "0.1")
pub interface SearchClient {
  /// Index a single document.
  async func index(doc: in SearchDocument): Result[IndexResult, SearchError]
    requires: doc.index.length > 0
    requires: doc.id.length > 0

  /// Index a batch of documents in a single request.
  async func indexBatch(docs: in slice[SearchDocument]): Result[slice[IndexResult], SearchError]

  /// Execute a search query and return matching hits.
  async func search(query: in SearchQuery): Result[SearchResult, SearchError]
    requires: query.index.length > 0

  /// Return autocomplete suggestions for `text` on `field` in `index`.
  async func suggest(index: in String, text: in String, field: in String, size: in Int): Result[SuggestResult, SearchError]
    requires: index.length > 0
    requires: field.length > 0
    requires: size > 0

  /// Delete a single document by ID.
  async func delete(index: in String, id: in String): Result[Unit, SearchError]
    requires: index.length > 0
    requires: id.length > 0

  /// Delete an entire index.
  async func deleteIndex(index: in String): Result[Unit, SearchError]
    requires: index.length > 0

  /// Return whether a document exists.
  async func exists(index: in String, id: in String): Result[Bool, SearchError]
    requires: index.length > 0
    requires: id.length > 0

  /// Create an index with the given mapping JSON.  For Elasticsearch this
  /// is the raw `{"mappings": {...}, "settings": {...}}` body passed
  /// verbatim to `PUT /{index}`. Meilisearch has no equivalent up-front
  /// schema; a non-empty `mappingJson` is instead applied via
  /// `PATCH /indexes/{index}/settings` after index creation — see
  /// `meilisearch_backend.l`'s `backendCreateIndex`.
  async func createIndex(index: in String, mappingJson: in String): Result[Unit, SearchError]
    requires: index.length > 0
}

// ─── Native client ────────────────────────────────────────────────────────────
/// HTTP-backed search client.  Obtain via the factory functions.  Holds a
/// `Std.Rest.RestClient` pre-configured with the backend's base URL and
/// auth strategy; every operation below delegates to the active backend's
/// `backend*` functions (`elasticsearch_backend.l` or
/// `meilisearch_backend.l` — exactly one is compiled in per build, per
/// `lyric.toml`'s `elasticsearch` / `meilisearch` features).
@stable(since = "0.1")
pub record NativeSearchClient {
  cfg: HttpConfig
}

impl SearchClient for NativeSearchClient {
  async func index(doc: in SearchDocument): Result[IndexResult, SearchError] {
    return await backendIndex(self.cfg, doc)
  }

  async func indexBatch(docs: in slice[SearchDocument]): Result[slice[IndexResult], SearchError] {
    return await backendIndexBatch(self.cfg, docs)
  }

  async func search(query: in SearchQuery): Result[SearchResult, SearchError] {
    val result = await backendSearch(self.cfg, query)
    return result
  }

  async func suggest(
    index: in String, text: in String, field: in String, size: in Int
  ): Result[SuggestResult, SearchError] {
    return await backendSuggest(self.cfg, index, text, field, size)
  }

  async func delete(index: in String, id: in String): Result[Unit, SearchError] {
    return await backendDelete(self.cfg, index, id)
  }

  async func deleteIndex(index: in String): Result[Unit, SearchError] {
    return await backendDeleteIndex(self.cfg, index)
  }

  async func exists(index: in String, id: in String): Result[Bool, SearchError] {
    return await backendExists(self.cfg, index, id)
  }

  async func createIndex(index: in String, mappingJson: in String): Result[Unit, SearchError] {
    return await backendCreateIndex(self.cfg, index, mappingJson)
  }
}

// ─── Factory ──────────────────────────────────────────────────────────────────
/// Connect to Elasticsearch.  Performs a `GET /` health probe so a
/// connection failure surfaces immediately, rather than on the first real
/// operation.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub async func connectElasticsearch(
  url: in String,
  apiKey: in String,
  username: in String,
  password: in String,
  connectTimeoutMs: in Int,
  requestTimeoutMs: in Int,
): Result[SearchClient, SearchError]
  requires: url.length > 0
{
  val connected = await backendConnectElasticsearch(url, apiKey, username, password, connectTimeoutMs, requestTimeoutMs)
  match connected {
    case Err(e) -> return Err(error = e)
    case Ok(cfg) -> {
      val client: SearchClient = NativeSearchClient(cfg = cfg)
      return Ok(value = client)
    }
  }
}

/// Connect to Meilisearch.  Performs a `GET /health` probe so a connection
/// failure surfaces immediately, rather than on the first real operation.
@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub async func connectMeilisearch(
  url: in String, apiKey: in String, connectTimeoutMs: in Int
): Result[SearchClient, SearchError]
  requires: url.length > 0
{
  val connected = await backendConnectMeilisearch(url, apiKey, connectTimeoutMs)
  match connected {
    case Err(e) -> return Err(error = e)
    case Ok(cfg) -> {
      val client: SearchClient = NativeSearchClient(cfg = cfg)
      return Ok(value = client)
    }
  }
}

/// Dispatch to the configured backend by name, reading connection settings
/// from the `LYRIC_SEARCH_*` environment variables documented at the top of
/// this file. Returns Err for a provider string that does not match the
/// backend feature compiled into this build (`@cfg(feature =
/// "elasticsearch")` / `@cfg(feature = "meilisearch")` — see lyric.toml; the
/// two features are mutually exclusive per build).
@experimental
@cfg(feature = "elasticsearch")
pub async func connect(provider: in String): Result[SearchClient, SearchError]
  requires: provider.length > 0
{
  if provider == "elasticsearch" {
    val url = getVarOrDefault("LYRIC_SEARCH_ELASTICSEARCH_URL", "")
    if url.length == 0 {
      return Err(
        error = SearchError(
          message = "LYRIC_SEARCH_ELASTICSEARCH_URL is not set",
          code = "MISSING_CONFIG",
          statusCode = 0
        )
      )
    }
    val username = getVarOrDefault("LYRIC_SEARCH_ELASTICSEARCH_USERNAME", "")
    val password = getVarOrDefault("LYRIC_SEARCH_ELASTICSEARCH_PASSWORD", "")
    val requestTimeoutMs = parseIntOrDefault(getVarOrDefault("LYRIC_SEARCH_ELASTICSEARCH_TIMEOUT_MS", "30000"), 30000)
    return await connectElasticsearch(url, "", username, password, 10000, requestTimeoutMs)
  }
  return Err(
    error = SearchError(
      message = "Unknown search provider: " + provider + ". This build only supports \"elasticsearch\".",
      code = "UNKNOWN_PROVIDER",
      statusCode = 0
    )
  )
}

@experimental
@cfg(feature = "meilisearch")
pub async func connect(provider: in String): Result[SearchClient, SearchError]
  requires: provider.length > 0
{
  if provider == "meilisearch" {
    val url = getVarOrDefault("LYRIC_SEARCH_MEILISEARCH_URL", "")
    if url.length == 0 {
      return Err(
        error = SearchError(
          message = "LYRIC_SEARCH_MEILISEARCH_URL is not set",
          code = "MISSING_CONFIG",
          statusCode = 0
        )
      )
    }
    val apiKey = getVarOrDefault("LYRIC_SEARCH_MEILISEARCH_API_KEY", "")
    val requestTimeoutMs = parseIntOrDefault(getVarOrDefault("LYRIC_SEARCH_MEILISEARCH_TIMEOUT_MS", "30000"), 30000)
    return await connectMeilisearch(url, apiKey, requestTimeoutMs)
  }
  return Err(
    error = SearchError(
      message = "Unknown search provider: " + provider + ". This build only supports \"meilisearch\".",
      code = "UNKNOWN_PROVIDER",
      statusCode = 0
    )
  )
}

// ─── Convenience helpers ──────────────────────────────────────────────────────
// These are plain (non-`async`) functions, not `async func`, even though
// their bodies `await` an interface-dispatched call. That's deliberate: an
// `async func` whose state machine awaits a `SearchClient`-interface-
// dispatched call (`client.search(...)` etc.) throws `System.
// InvalidProgramException` at runtime — a third defect in the same family
// documented at `HttpConfig`'s declaration above, reproduced independently
// of the Std.Http ones (this one is triggered by `Search`'s *own*
// interface, `SearchClient`, not `Std.Http`'s). A plain function awaiting
// the same call directly ("awaits in place" — see
// docs/01-language-reference.md's async section) does not hit it. Callers
// may still `await Search.search(client, query)` etc. from their own
// code — direct calls to a function work with or without `await` — but a
// caller who writes their OWN `async func` around a raw `client.search(...)`
// call (bypassing these helpers) can hit the same defect; prefer these
// helpers, or `NativeSearchClient`'s own async impl methods called
// directly from a non-`async` context, over rolling your own async
// wrapper around the interface.
/// Index a single document.
@stable(since = "0.1")
pub func index(client: in SearchClient, doc: in SearchDocument): Result[IndexResult, SearchError]
  requires: doc.index.length > 0
  requires: doc.id.length > 0
{
  return await client.index(doc)
}

/// Execute a search query.
@stable(since = "0.1")
pub func search(client: in SearchClient, query: in SearchQuery): Result[SearchResult, SearchError]
  requires: query.index.length > 0
{
  return await client.search(query)
}

/// Execute a simple keyword search with default pagination (from=0, size=10).
@stable(since = "0.1")
pub func searchSimple(client: in SearchClient, index: in String, query: in String): Result[SearchResult, SearchError]
  requires: index.length > 0
{
  val q = SearchQuery(index = index, query = query, filters = [], from = 0, size = 10, sort = [], highlightFields = [])
  return await client.search(q)
}

/// Delete a document by index and ID.
@stable(since = "0.1")
pub func delete(client: in SearchClient, index: in String, id: in String): Result[Unit, SearchError]
  requires: index.length > 0
  requires: id.length > 0
{
  return await client.delete(index, id)
}

/// Return autocomplete suggestions using a default size of 5.
@stable(since = "0.1")
pub func suggest(
  client: in SearchClient, index: in String, text: in String, field: in String
): Result[SuggestResult, SearchError]
  requires: index.length > 0
  requires: field.length > 0
{
  return await client.suggest(index, text, field, 5)
}

/// Build a SearchQuery with default pagination and no filters, sort, or highlights.
@stable(since = "0.1")
pub func makeQuery(index: in String, query: in String): SearchQuery
  requires: index.length > 0
{
  return SearchQuery(index = index, query = query, filters = [], from = 0, size = 10, sort = [], highlightFields = [])
}

/// Build an equality filter.
@stable(since = "0.1")
pub func makeFilter(field: in String, value: in String): SearchFilter
  requires: field.length > 0
{
  return SearchFilter(field = field, value = value, operator = "eq")
}

/// Build a sort specification.
@stable(since = "0.1")
pub func makeSort(field: in String, descending: in Bool): SortField
  requires: field.length > 0
{
  return SortField(field = field, descending = descending)
}

/// Build a SearchDocument from an index name, ID, and field map.
@stable(since = "0.1")
pub func makeDoc(index: in String, id: in String, fields: in Map[String, String]): SearchDocument
  requires: index.length > 0
  requires: id.length > 0
{
  return SearchDocument(id = id, index = index, fields = fields)
}

// ─── Shared helpers used by both backend files ───────────────────────────────
// (elasticsearch_backend.l / meilisearch_backend.l — same package, so these
// package-private helpers are visible there without an import; see
// docs/19-multi-file-packages.md.)
func parseIntOrDefault(s: in String, default: in Int): Int {
  match parseOptInt(s) {
    case Some(n) -> n
    case None -> default
  }
}

/// Percent-encode a single URL path segment (RFC 3986 unreserved set is
/// kept literal; everything else, including `/`, is escaped).  Both
/// backends key documents by caller-supplied `index`/`id` strings that may
/// contain characters unsafe in a URL path segment.
pub func pathEscape(s: in String): String {
  var result = ""
  var i = 0
  while i < s.length {
    val c = s[i]
    if isAsciiLetterOrDigit(c) or c == '-' or c == '_' or c == '.' or c == '~' {
      result = result + c.toString()
    } else {
      val bytes = encodeUtf8(c.toString())
      var j = 0
      while j < bytes.length {
        result = result + "%" + encodeHex([bytes[j]])
        j = j + 1
      }
    }
    i = i + 1
  }
  return result
}

/// Convert a JSON scalar element to a String for storage in a
/// `Map[String, String]` (`SearchHit.source`).  Non-scalar values (nested
/// objects/arrays) fall back to their raw JSON text.
func jsonScalarToString(v: in JsonElement): String {
  val kind = valueKind(v)
  if kind == 3 {
    return getString(v)
  }
  if kind == 5 {
    return "true"
  }
  if kind == 6 {
    return "false"
  }
  if kind == 7 {
    return ""
  }
  return getRawText(v)
}

// ─── HTTP transport (direct Std.Http, not Std.Rest) ──────────────────────────
// `Std.Rest.RestClient`'s `get`/`post`/`put`/`patch`/`delete` are plain
// top-level `pub async func`s. They throw `System.MissingMethodException`
// at runtime when reached through `Std.Rest`'s own `sendRequest`, which
// itself calls `Std.Http`'s free async functions (`sendAsync`/`getAsync`/
// `postAsync`) — the exact cross-package free-async-function defect
// `lyric-lambda/src/dispatch.l`'s header comment documents in detail
// (reproduced there with a 10-line, zero-Lambda-code repro). This package
// builds its HTTP layer directly on `Std.Http` instead — but two more,
// previously-undocumented defects in `Std.Http`/interface-async-dispatch
// were found and characterized while doing that (each reproduced
// standalone with a ~15-line repro carrying zero Search code):
//
//   1. `HttpClient.send(req)` (an *interface* method, not a free
//      function) ALSO throws at runtime ("unsupported method 'send' on
//      the receiver type...") when called from any package other than
//      `Std.Http` itself — from *inside* an `async func`. Calling it from
//      a plain (non-async) function wrapped in `try { await
//      client.send(req) } catch Bug as bug { ... }` reliably catches it
//      as an ordinary `Bug` — V0012 forbids that same `try`/`await`
//      combination inside an `async func` ("await inside a try/catch/
//      finally... emits invalid IL"), which is *why* `sendRequest`/
//      `sendRequestRaw` below (and `sendCatching`, which they share) are
//      plain funcs, not `async func`, despite calling an async interface
//      method internally (a direct call to an async function "awaits in
//      place" from a synchronous caller — see
//      docs/01-language-reference.md's async section). WORKED AROUND.
//   2. An `async func` that itself `await`s a call dispatched through
//      *any* interface (this reproduces with `Search`'s own
//      `SearchClient`, not just `Std.Http`'s `HttpClient` — it is not
//      `Std.Http`-specific) throws `System.InvalidProgramException` (bad
//      IL) at runtime. Calling the same interface method from a plain
//      (non-async) function does not. This is *why* the convenience
//      wrappers below (`index`/`search`/`searchSimple`/`delete`/
//      `suggest`) are plain funcs rather than `async func`, even though
//      each is a one-line forward to `client.<method>(...)`. WORKED
//      AROUND for this package's own call sites; a caller who writes
//      their *own* `async func` wrapping a raw `client.search(...)` call
//      (bypassing these helpers) can still hit it.
//   3. `HttpResponse.bodyText(response)` throws a raw
//      `System.MissingMethodException` (not a Lyric `Bug`) under the same
//      cross-package condition as defect 1 — `try`/`catch Bug` does NOT
//      catch it, in an `async func` or otherwise. NOT WORKED AROUND: no
//      catchable failure mode was found, and `HttpResponse`'s internals
//      are opaque to this package, so there is no lower-level escape
//      hatch either. Reading a real response body from outside
//      `Std.Http` is not currently possible. `readJsonBody` below is
//      therefore unavoidably a hard crash if a request actually reaches a
//      live server that returns a body — every code path this package's
//      own tests exercise fails before reaching that point (connection
//      refused at `send`, caught by defect 1's workaround), so this crash
//      is untested-but-real, not merely theoretical, and is the one
//      remaining live-connectivity blocker.
//
// None of the three can be fixed from this directory (all are
// `lyric-compiler`/`lyric-stdlib` bugs, each reproduced with zero Search
// code). This also means `Search` cannot use `Std.Rest.RestAuth`/
// `RestClient`'s base-URL-plus-headers convenience; `HttpConfig` below is
// this package's own (much smaller) equivalent.
/// Everything a backend needs to send an authenticated request: the
/// shared `HttpClient`, the connection's base URL, and an optional single
/// auth header (`authHeaderName` empty means no auth header is sent).
pub opaque type HttpConfig {
  client: HttpClient
  baseUrl: String
  authHeaderName: String
  authHeaderValue: String
}

/// Construct an `HttpConfig` directly (bypassing `connectElasticsearch`/
/// `connectMeilisearch`'s health probe).  Exposed for tests that need to
/// exercise `NativeSearchClient`'s generic operations against a specific
/// `HttpClient` without a live backend.
@stable(since = "0.1")
pub func HttpConfig.new(
  client: in HttpClient, baseUrl: in String, authHeaderName: in String, authHeaderValue: in String
): HttpConfig {
  return HttpConfig(
    client = client,
    baseUrl = baseUrl,
    authHeaderName = authHeaderName,
    authHeaderValue = authHeaderValue
  )
}

/// Join `baseUrl` and `path`, collapsing the doubled `/` when both the
/// base ends with one and the path starts with one.  Mirrors
/// `Std.Rest`'s (unusable, see above) `fullUrl`.
func joinUrl(baseUrl: in String, path: in String): String {
  if path.length == 0 {
    return baseUrl
  }
  val lastBase = baseUrl.length - 1
  val baseEndsSlash = baseUrl[lastBase] == '/'
  val pathStartsSlash = path[0] == '/'
  if baseEndsSlash and pathStartsSlash {
    return baseUrl + path.substring(1, path.length)
  }
  if baseEndsSlash or pathStartsSlash {
    return baseUrl + path
  }
  return baseUrl + "/" + path
}

/// Extract the HTTP status code carried by an HttpError, or 0 when the
/// failure occurred below the HTTP layer (DNS, connect, timeout — those
/// never get a status code).
func httpErrorStatusCode(e: in HttpError): Int {
  match e {
    case BadStatus(url, statusCode) -> statusCode
    case _ -> 0
  }
}

/// Convert a transport-level HttpError into a typed SearchError, tagging
/// it with the given operation code (e.g. "INDEX_FAILED").
pub func toSearchError(e: in HttpError, code: in String): SearchError {
  return SearchError(message = HttpError.message(e), code = code, statusCode = httpErrorStatusCode(e))
}

func buildRequest(
  cfg: in HttpConfig, method: in HttpMethod, path: in String, body: in Option[String]
): Result[HttpRequest, SearchError] {
  val url = joinUrl(cfg.baseUrl, path)
  match Url.tryFrom(url) {
    case Err(e) -> return Err(error = toSearchError(e, "INVALID_URL"))
    case Ok(parsed) -> {
      var req = request(method, parsed)
      if cfg.authHeaderName.length > 0 {
        req = withHeader(req, cfg.authHeaderName, cfg.authHeaderValue)
      }
      match body {
        case Some(json) -> {
          req = withJsonBody(req, json)
        }
        case None -> ()
      }
      return Ok(value = req)
    }
  }
}

/// Call `client.send(req)`, catching the cross-package `HttpClient.send`
/// dispatch defect described at the top of this file (defect 1). Must be
/// a plain (non-`async`) function: V0012 rejects `await` inside `try` in
/// an `async func`, but a synchronous caller may freely `await` an async
/// call ("awaits in place").
func sendCatching(client: in HttpClient, req: in HttpRequest, url: in String): Result[HttpResponse, HttpError] {
  return try {
    await client.send(req)
  } catch Bug as bug {
    Err(
      error = ConnectionFailed(
        url = url,
        message = "Std.Http cross-package `HttpClient.send` dispatch failure (compiler defect, see this file's header): " +
          bug.message
      )
    )
  }
}

/// Send a request and require a 2xx response, tagging any failure
/// (transport or non-2xx status) with `code`.
pub func sendRequest(
  cfg: in HttpConfig,
  method: in HttpMethod,
  path: in String,
  body: in Option[String],
  code: in String,
): Result[HttpResponse, SearchError] {
  match buildRequest(cfg, method, path, body) {
    case Err(e) -> return Err(error = e)
    case Ok(req) -> {
      val url = joinUrl(cfg.baseUrl, path)
      match sendCatching(cfg.client, req, url) {
        case Err(e) -> return Err(error = toSearchError(e, code))
        case Ok(response) -> match HttpResponse.ensureSuccess(response) { case Err(e) -> return Err(error = toSearchError(e, code)); case Ok(ok) -> return Ok(value = ok) }
      }
    }
  }
}

/// Send a request without requiring 2xx — for operations (`exists`) that
/// need to distinguish 404 from other statuses themselves.
pub func sendRequestRaw(
  cfg: in HttpConfig, method: in HttpMethod, path: in String, code: in String
): Result[HttpResponse, SearchError] {
  match buildRequest(cfg, method, path, None) {
    case Err(e) -> return Err(error = e)
    case Ok(req) -> {
      val url = joinUrl(cfg.baseUrl, path)
      match sendCatching(cfg.client, req, url) {
        case Err(e) -> return Err(error = toSearchError(e, code))
        case Ok(response) -> return Ok(value = response)
      }
    }
  }
}

/// Read a response body and parse it as JSON, tagging any failure with
/// `code`.  Caller MUST `disposeJson` the returned doc.
///
/// UNLIKE `sendRequest`/`sendRequestRaw`, this has no defensive wrapper:
/// `HttpResponse.bodyText` throws a raw `System.MissingMethodException`
/// (defect 2 above), which `try`/`catch Bug` cannot catch on any target.
/// Reaching this function against a real, reachable server is a hard
/// crash today. Every path this package's tests exercise fails at
/// `sendRequest`/`sendCatching` first (closed port / no configured
/// server), so the crash is real but not exercised by CI.
pub async func readJsonBody(response: in HttpResponse, code: in String): Result[JsonDoc, SearchError] {
  match await HttpResponse.bodyText(response) {
    case Err(e) -> return Err(error = SearchError(message = IOError.message(e), code = code, statusCode = 0))
    case Ok(text) -> return Ok(value = parseJson(text))
  }
}
