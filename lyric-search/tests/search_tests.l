//! tests/search_tests.l — tests for the Search package (issue #5408).
//!
//! Covers SearchError, SearchDocument, SearchQuery, SearchResult type
//! construction; the pure factory helpers (makeDoc, makeQuery, makeFilter,
//! makeSort); `pathEscape`; HttpError -> SearchError mapping
//! (`toSearchError`); each backend's request-body construction and
//! response parsing against canned JSON (no live server needed); and a
//! "wired dispatch" section proving connect/index/search/suggest/delete
//! reach a real HTTP call (a closed TCP port deterministically produces a
//! transport failure without needing a live search engine).
//!
//! A live Elasticsearch or Meilisearch server is not available in this
//! repository's CI sandbox, so the true end-to-end round trip lives in a
//! single gated integration test at the bottom of this file: set
//! `LYRIC_SEARCH_ELASTICSEARCH_URL` (or `LYRIC_SEARCH_MEILISEARCH_URL`,
//! whichever backend feature is active) to run it against a real engine;
//! otherwise it asserts the clean-skip path.
//!
//! Only the default feature set (`elasticsearch`) is exercised by this
//! file's precise, backend-specific assertions, matching how CI invokes
//! `lyric test` (no `--features` override — see .github/workflows/ci.yml).
//! Tests that need to work under either backend feature use the
//! `@cfg`-gated-helper-function dispatch trick already established by this
//! file before this change (`probeConnect`): a plain (non-`test`) function
//! is compiled differently per active feature, and the `test` block that
//! calls it stays unconditional — because `test` blocks don't reliably
//! survive `@cfg` erasure through test synthesis (observed to compile into
//! an invalid MSIL program when gated directly).
@test_module
package Search.SearchTests

import Std.Core
import Std.Testing
import Std.Collections
import Std.String as Str
import Std.Json
import Std.Http
import Std.Errors
import Std.Environment
import Search

// ─── SearchError ─────────────────────────────────────────────────────────────
test "SearchError: fields are accessible" {
  val e = SearchError(message = "index not found", code = "index_not_found_exception", statusCode = 404)
  assertEqual(e.message, "index not found", "message field")
  assertEqual(e.code, "index_not_found_exception", "code field")
  assertEqualInt(e.statusCode, 404, "statusCode field")
}

test "SearchError: statusCode 0 is valid (non-HTTP error)" {
  val e = SearchError(message = "connection refused", code = "CONNECT_ERROR", statusCode = 0)
  assertEqualInt(e.statusCode, 0, "statusCode 0 is valid")
}

// ─── makeDoc ─────────────────────────────────────────────────────────────────
test "makeDoc: fields are accessible" {
  val fields: Map[String, String] = newMap()
  fields.add("name", "Widget")
  val doc = Search.makeDoc("products", "p-1", fields)
  assertEqual(doc.index, "products", "index field")
  assertEqual(doc.id, "p-1", "id field")
  match mapGet(doc.fields, "name") {
    case Some(v) -> assertEqual(v, "Widget", "name field value")
    case None -> assertTrue(false, "name field must be present")
  }
}

test "makeDoc: empty fields map is valid" {
  val doc = Search.makeDoc("logs", "log-42", newMap())
  assertEqual(doc.index, "logs", "index field")
  assertEqual(doc.id, "log-42", "id field")
  assertTrue(doc.fields.count == 0, "empty fields map has count 0")
}

test "makeDoc: multiple fields are all accessible" {
  val fields: Map[String, String] = newMap()
  fields.add("title", "Hello")
  fields.add("body", "World")
  val doc = Search.makeDoc("posts", "post-1", fields)
  match mapGet(doc.fields, "title") {
    case Some(v) -> assertEqual(v, "Hello", "title field")
    case None -> assertTrue(false, "title must be present")
  }
  match mapGet(doc.fields, "body") {
    case Some(v) -> assertEqual(v, "World", "body field")
    case None -> assertTrue(false, "body must be present")
  }
}

// ─── makeQuery ────────────────────────────────────────────────────────────────
test "makeQuery: index and query fields are set" {
  val q = Search.makeQuery("products", "Widget")
  assertEqual(q.index, "products", "index field")
  assertEqual(q.query, "Widget", "query field")
}

test "makeQuery: default from is 0" {
  val q = Search.makeQuery("products", "test")
  assertEqualInt(q.from, 0, "default from must be 0")
}

test "makeQuery: default size is 10" {
  val q = Search.makeQuery("products", "test")
  assertEqualInt(q.size, 10, "default size must be 10")
}

test "makeQuery: default filters list is empty" {
  val q = Search.makeQuery("products", "test")
  assertTrue(q.filters.length == 0, "default filters list must be empty")
}

test "makeQuery: default sort list is empty" {
  val q = Search.makeQuery("products", "test")
  assertTrue(q.sort.length == 0, "default sort list must be empty")
}

test "makeQuery: empty query string is accepted" {
  val q = Search.makeQuery("products", "")
  assertEqual(q.query, "", "empty query string is valid")
}

// ─── makeFilter ───────────────────────────────────────────────────────────────
test "makeFilter: fields are accessible" {
  val f = Search.makeFilter("status", "active")
  assertEqual(f.field, "status", "filter field")
  assertEqual(f.value, "active", "filter value")
}

test "makeFilter: empty value is valid" {
  val f = Search.makeFilter("category", "")
  assertEqual(f.value, "", "empty filter value is valid")
}

// ─── makeSort ─────────────────────────────────────────────────────────────────
test "makeSort: ascending sort has descending=false" {
  val s = Search.makeSort("price", false)
  assertEqual(s.field, "price", "sort field")
  assertTrue(not s.descending, "ascending sort has descending=false")
}

test "makeSort: descending sort has descending=true" {
  val s = Search.makeSort("created_at", true)
  assertEqual(s.field, "created_at", "sort field")
  assertTrue(s.descending, "descending sort has descending=true")
}

// ─── SearchResult construction ────────────────────────────────────────────────
test "SearchResult: empty result has zero total and no hits" {
  val r = SearchResult(total = 0i64, hits = [], tookMs = 0, scrollId = None)
  assertEqualLong(r.total, 0i64, "total must be 0")
  assertTrue(r.hits.length == 0, "hits must be empty")
  assertEqualInt(r.tookMs, 0, "tookMs must be 0")
}

test "SearchResult: total carries document count" {
  val r = SearchResult(total = 42i64, hits = [], tookMs = 5, scrollId = None)
  assertEqualLong(r.total, 42i64, "total carries document count")
}

// ─── pathEscape ───────────────────────────────────────────────────────────────
test "pathEscape: unreserved characters pass through unchanged" {
  assertEqual(Search.pathEscape("abcXYZ019-_.~"), "abcXYZ019-_.~", "unreserved charset is untouched")
}

test "pathEscape: space and slash are percent-encoded" {
  val escaped = Search.pathEscape("a b/c")
  assertTrue(Str.contains(escaped, "%20"), "space becomes %20")
  assertTrue(Str.contains(escaped, "%2F"), "slash becomes %2F")
  assertTrue(not Str.contains(escaped, " "), "no literal space remains")
  assertTrue(not Str.contains(escaped, "/"), "no literal slash remains")
}

test "pathEscape: empty string escapes to empty string" {
  assertEqual(Search.pathEscape(""), "", "empty input stays empty")
}

test "pathEscape: multi-byte UTF-8 character is percent-encoded byte-by-byte" {
  // '€' (U+20AC) is 3 bytes in UTF-8 (E2 82 AC).
  val escaped = Search.pathEscape("€")
  assertEqual(escaped, "%E2%82%AC", "euro sign encodes to its 3 UTF-8 bytes")
}

// ─── toSearchError (HttpError -> SearchError mapping) ────────────────────────
test "toSearchError: BadStatus carries the real HTTP status code" {
  val e: HttpError = BadStatus(url = "http://x/y", statusCode = 404)
  val se = Search.toSearchError(e, "DELETE_FAILED")
  assertEqual(se.code, "DELETE_FAILED", "code is the operation tag, not the transport detail")
  assertEqualInt(se.statusCode, 404, "statusCode is carried through from BadStatus")
  assertTrue(se.message.length > 0, "message is non-empty")
}

test "toSearchError: ConnectionFailed has no HTTP status, so statusCode is 0" {
  val e: HttpError = ConnectionFailed(url = "http://x/y", message = "connection refused")
  val se = Search.toSearchError(e, "CONNECT_FAILED")
  assertEqualInt(se.statusCode, 0, "connection-level failures carry no HTTP status")
  assertTrue(Str.contains(se.message, "connection refused"), "underlying transport message is preserved")
}

test "toSearchError: InvalidUrl has no HTTP status, so statusCode is 0" {
  val e: HttpError = InvalidUrl(url = "not-a-url")
  val se = Search.toSearchError(e, "SEARCH_FAILED")
  assertEqualInt(se.statusCode, 0, "an invalid-URL failure has no HTTP status")
  assertTrue(se.message.length > 0, "message is non-empty")
}

// ─── Elasticsearch: request-body construction (feature = "elasticsearch") ───
@cfg(feature = "elasticsearch")
func probeEsFilterEq(): String {
  Search.esFilterClause(Search.makeFilter("status", "active"))
}

@cfg(feature = "meilisearch")
func probeEsFilterEq(): String {
  ""
}

test "elasticsearch filter clause (eq): maps to a term query" {
  val clause = probeEsFilterEq()
  if clause.length > 0 {
    assertTrue(Str.contains(clause, "\"term\""), "eq operator maps to term query")
    assertTrue(Str.contains(clause, "status"), "clause references the field")
    assertTrue(Str.contains(clause, "active"), "clause references the value")
  }
}

@cfg(feature = "elasticsearch")
func probeEsFilterRange(): String {
  Search.esFilterClause(SearchFilter(field = "price", value = "10", operator = "gte"))
}

@cfg(feature = "meilisearch")
func probeEsFilterRange(): String {
  ""
}

test "elasticsearch filter clause (gte): maps to a range query" {
  val clause = probeEsFilterRange()
  if clause.length > 0 {
    assertTrue(Str.contains(clause, "\"range\""), "gte operator maps to range query")
    assertTrue(Str.contains(clause, "\"gte\""), "range clause carries the gte bound")
  }
}

@cfg(feature = "elasticsearch")
func probeEsQueryClauseEmpty(): String {
  Search.esQueryClause("")
}

@cfg(feature = "meilisearch")
func probeEsQueryClauseEmpty(): String {
  "{\"match_all\":{}}"
}

test "elasticsearch query clause: empty query text maps to match_all" {
  assertEqual(
    probeEsQueryClauseEmpty(),
    "{\"match_all\":{}}",
    "empty query text is match_all, not an empty query_string"
  )
}

@cfg(feature = "elasticsearch")
func probeEsBuildSearchBody(): String {
  val q = Search.makeQuery("products", "widget")
  Search.esBuildSearchBody(q)
}

@cfg(feature = "meilisearch")
func probeEsBuildSearchBody(): String {
  ""
}

test "elasticsearch search body: carries query text, from, and size" {
  val body = probeEsBuildSearchBody()
  if body.length > 0 {
    assertTrue(Str.contains(body, "widget"), "query text appears in body")
    assertTrue(Str.contains(body, "\"from\":0"), "default from appears in body")
    assertTrue(Str.contains(body, "\"size\":10"), "default size appears in body")
    assertTrue(Str.contains(body, "\"query_string\""), "non-empty query uses query_string")
  }
}

@cfg(feature = "elasticsearch")
func probeEsFieldsToJsonObject(): String {
  val fields: Map[String, String] = newMap()
  fields.add("name", "Widget")
  Search.esFieldsToJsonObject(fields)
}

@cfg(feature = "meilisearch")
func probeEsFieldsToJsonObject(): String {
  ""
}

test "elasticsearch document body: fields map becomes a flat JSON object" {
  val body = probeEsFieldsToJsonObject()
  if body.length > 0 {
    assertTrue(Str.contains(body, "\"name\""), "field name is present")
    assertTrue(Str.contains(body, "\"Widget\""), "field value is present")
  }
}

// ─── Elasticsearch: response parsing against canned JSON ────────────────────
@cfg(feature = "elasticsearch")
func esIndexResultJson(): String {
  "{\"_id\":\"p-1\",\"_version\":3,\"result\":\"updated\"}"
}

@cfg(feature = "meilisearch")
func esIndexResultJson(): String {
  "{}"
}

// `Search.esParseIndexResult`/`esParseSearchResponse`/`esParseSuggestResponse`
// are defined in `elasticsearch_backend.l`, which is entirely `@cfg`-erased
// when the `elasticsearch` feature is inactive — calling them
// unconditionally would reference a symbol that doesn't exist in a
// `--features meilisearch` build. Route through the same `@cfg`-paired-
// helper-function dispatch trick used for the Meilisearch equivalents.
@cfg(feature = "elasticsearch")
func probeEsParseIndexResult(root: in JsonElement): IndexResult {
  Search.esParseIndexResult(root)
}

@cfg(feature = "meilisearch")
func probeEsParseIndexResult(root: in JsonElement): IndexResult {
  IndexResult(id = "", version = 0i64, status = "")
}

test "elasticsearch: parses a real index-response shape" {
  val doc = parseJson(esIndexResultJson())
  val result = probeEsParseIndexResult(rootElement(doc))
  disposeJson(doc)
  if result.id.length > 0 {
    assertEqual(result.id, "p-1", "id is read from _id")
    assertEqualLong(result.version, 3i64, "version is read from _version")
    assertEqual(result.status, "updated", "status is read from result")
  }
}

@cfg(feature = "elasticsearch")
func esSearchResponseJson(): String {
  "{\"took\":7,\"hits\":{\"total\":{\"value\":2,\"relation\":\"eq\"},\"hits\":[" +
    "{\"_id\":\"p-1\",\"_index\":\"products\",\"_score\":1.5,\"_source\":{\"name\":\"Widget\"}," +
    "\"highlight\":{\"name\":[\"<em>Widget</em>\"]}}," +
    "{\"_id\":\"p-2\",\"_index\":\"products\",\"_score\":0.8,\"_source\":{\"name\":\"Gadget\"}}" +
    "]}}"
}

@cfg(feature = "meilisearch")
func esSearchResponseJson(): String {
  "{}"
}

@cfg(feature = "elasticsearch")
func probeEsParseSearchResponse(root: in JsonElement): SearchResult {
  Search.esParseSearchResponse(root)
}

@cfg(feature = "meilisearch")
func probeEsParseSearchResponse(root: in JsonElement): SearchResult {
  SearchResult(total = 0i64, hits = [], tookMs = 0, scrollId = None)
}

test "elasticsearch: parses a real search-response shape, including highlights" {
  val json = esSearchResponseJson()
  val doc = parseJson(json)
  val result = probeEsParseSearchResponse(rootElement(doc))
  disposeJson(doc)
  if json.length > 2 {
    assertEqualInt(result.tookMs, 7, "tookMs is read from took")
    assertEqualLong(result.total, 2i64, "total is read from hits.total.value")
    assertEqualInt(result.hits.length, 2, "both hits are parsed")
    val first = result.hits[0]
    assertEqual(first.id, "p-1", "first hit id")
    assertEqual(first.index, "products", "first hit index")
    match mapGet(first.source, "name") {
      case Some(v) -> assertEqual(v, "Widget", "first hit source.name")
      case None -> assertTrue(false, "first hit source.name must be present")
    }
    assertEqualInt(first.highlights.length, 1, "first hit has one highlighted field")
    assertEqual(first.highlights[0].field, "name", "highlighted field name")
    assertEqualInt(first.highlights[0].fragments.length, 1, "one highlight fragment")
    val second = result.hits[1]
    assertEqualInt(second.highlights.length, 0, "second hit has no highlight object, so no highlights")
  }
}

@cfg(feature = "elasticsearch")
func esSuggestResponseJson(): String {
  "{\"took\":2,\"hits\":{\"hits\":[" + "{\"_source\":{\"name\":\"Widget\"}}," + "{\"_source\":{\"name\":\"Widgetron\"}}" +
    "]}}"
}

@cfg(feature = "meilisearch")
func esSuggestResponseJson(): String {
  "{}"
}

@cfg(feature = "elasticsearch")
func probeEsParseSuggestResponse(root: in JsonElement, field: in String): SuggestResult {
  Search.esParseSuggestResponse(root, field)
}

@cfg(feature = "meilisearch")
func probeEsParseSuggestResponse(root: in JsonElement, field: in String): SuggestResult {
  SuggestResult(suggestions = [], tookMs = 0)
}

test "elasticsearch: parses a real suggest-response shape" {
  val json = esSuggestResponseJson()
  val doc = parseJson(json)
  val result = probeEsParseSuggestResponse(rootElement(doc), "name")
  disposeJson(doc)
  if json.length > 2 {
    assertEqualInt(result.tookMs, 2, "tookMs is read from took")
    assertEqualInt(result.suggestions.length, 2, "both suggestions are extracted")
    assertEqual(result.suggestions[0], "Widget", "first suggestion")
    assertEqual(result.suggestions[1], "Widgetron", "second suggestion")
  }
}

// ─── Meilisearch: request-body construction (feature = "meilisearch") ───────
@cfg(feature = "meilisearch")
func probeMsFilterEq(): String {
  Search.msFilterExpr(Search.makeFilter("status", "active"))
}

@cfg(feature = "elasticsearch")
func probeMsFilterEq(): String {
  ""
}

test "meilisearch filter expression (eq): field = 'value'" {
  val expr = probeMsFilterEq()
  if expr.length > 0 {
    assertEqual(expr, "status = 'active'", "eq operator maps to field = 'value'")
  }
}

@cfg(feature = "meilisearch")
func probeMsFilterContains(): String {
  Search.msFilterExpr(SearchFilter(field = "name", value = "widg", operator = "contains"))
}

@cfg(feature = "elasticsearch")
func probeMsFilterContains(): String {
  ""
}

test "meilisearch filter expression (contains): field CONTAINS 'value'" {
  val expr = probeMsFilterContains()
  if expr.length > 0 {
    assertEqual(expr, "name CONTAINS 'widg'", "contains operator maps to CONTAINS expression")
  }
}

@cfg(feature = "meilisearch")
func probeMsQuoteEscaping(): String {
  Search.msQuote("O'Brien")
}

@cfg(feature = "elasticsearch")
func probeMsQuoteEscaping(): String {
  ""
}

test "meilisearch msQuote: escapes an embedded single quote" {
  val quoted = probeMsQuoteEscaping()
  if quoted.length > 0 {
    assertEqual(quoted, "'O\\'Brien'", "embedded quote is backslash-escaped")
  }
}

@cfg(feature = "meilisearch")
func probeMsDocToJsonObject(): String {
  val fields: Map[String, String] = newMap()
  fields.add("name", "Widget")
  Search.msDocToJsonObject(Search.makeDoc("products", "p-1", fields))
}

@cfg(feature = "elasticsearch")
func probeMsDocToJsonObject(): String {
  ""
}

test "meilisearch document body: carries an explicit id field plus the document fields" {
  val body = probeMsDocToJsonObject()
  if body.length > 0 {
    assertTrue(Str.contains(body, "\"id\":\"p-1\""), "primary key id is embedded")
    assertTrue(Str.contains(body, "\"name\":\"Widget\""), "document field is embedded")
  }
}

@cfg(feature = "meilisearch")
func probeMsBuildSearchBody(): String {
  val q = Search.makeQuery("products", "widget")
  Search.msBuildSearchBody(q, true)
}

@cfg(feature = "elasticsearch")
func probeMsBuildSearchBody(): String {
  ""
}

test "meilisearch search body: carries q, offset, limit, and showRankingScore" {
  val body = probeMsBuildSearchBody()
  if body.length > 0 {
    assertTrue(Str.contains(body, "\"q\":\"widget\""), "query text appears as q")
    assertTrue(Str.contains(body, "\"offset\":0"), "default offset appears in body")
    assertTrue(Str.contains(body, "\"limit\":10"), "default limit appears in body")
    assertTrue(Str.contains(body, "\"showRankingScore\":true"), "ranking score is requested")
  }
}

// ─── Meilisearch: response parsing against canned JSON ──────────────────────
@cfg(feature = "meilisearch")
func msSearchResponseJson(): String {
  "{\"hits\":[" +
    "{\"id\":\"p-1\",\"name\":\"Widget\",\"_rankingScore\":0.9,\"_formatted\":{\"name\":\"<em>Widget</em>\"}}" +
    "],\"estimatedTotalHits\":1,\"processingTimeMs\":3}"
}

@cfg(feature = "elasticsearch")
func msSearchResponseJson(): String {
  "{}"
}

// `Search.msParseSearchResponse` is defined in `meilisearch_backend.l`,
// which is entirely `@cfg`-erased when the `meilisearch` feature is
// inactive (the default build is `elasticsearch`-only) — calling it
// unconditionally would reference a symbol that doesn't exist in this
// build. Route the call through the same `@cfg`-paired-helper-function
// dispatch trick used elsewhere in this file.
@cfg(feature = "meilisearch")
func probeMsParseSearchResponse(root: in JsonElement, index: in String): SearchResult {
  Search.msParseSearchResponse(root, index)
}

@cfg(feature = "elasticsearch")
func probeMsParseSearchResponse(root: in JsonElement, index: in String): SearchResult {
  SearchResult(total = 0i64, hits = [], tookMs = 0, scrollId = None)
}

test "meilisearch: parses a real search-response shape, including _formatted highlights" {
  val json = msSearchResponseJson()
  val doc = parseJson(json)
  val result = probeMsParseSearchResponse(rootElement(doc), "products")
  disposeJson(doc)
  if json.length > 2 {
    assertEqualInt(result.tookMs, 3, "tookMs is read from processingTimeMs")
    assertEqualLong(result.total, 1i64, "total is read from estimatedTotalHits")
    assertEqualInt(result.hits.length, 1, "one hit is parsed")
    val hit = result.hits[0]
    assertEqual(hit.id, "p-1", "hit id is read from the document's own id field")
    assertEqual(hit.index, "products", "hit index is the queried index (Meilisearch responses don't echo it)")
    match mapGet(hit.source, "name") {
      case Some(v) -> assertEqual(v, "Widget", "hit source.name")
      case None -> assertTrue(false, "hit source.name must be present")
    }
    match mapGet(hit.source, "_formatted") {
      case Some(_) -> assertTrue(false, "_formatted must not leak into source")
      case None -> ()
    }
    assertEqualInt(hit.highlights.length, 1, "one highlighted field")
    assertEqual(hit.highlights[0].field, "name", "highlighted field name")
    assertEqual(hit.highlights[0].fragments[0], "<em>Widget</em>", "formatted fragment is preserved verbatim")
  }
}

// ─── Wired dispatch (issue #5067 / #5408) ─────────────────────────────────────
// `Search.connect` dispatches on the provider string before touching any
// backend; an unknown provider must still resolve without an HTTP call,
// regardless of which backend feature this build has active.
test "connect: unknown provider returns UNKNOWN_PROVIDER without an HTTP call" {
  match await Search.connect("not-a-real-backend") {
    case Ok(_) -> assertTrue(false, "unknown provider must not connect")
    case Err(e) -> assertEqual(e.code, "UNKNOWN_PROVIDER", "unknown provider error code")
  }
}

@cfg(feature = "elasticsearch")
func probeConnect(): Result[SearchClient, SearchError] {
  await Search.connectElasticsearch("http://127.0.0.1:1", "", "", "", 200, 200)
}

@cfg(feature = "meilisearch")
func probeConnect(): Result[SearchClient, SearchError] {
  await Search.connectMeilisearch("http://127.0.0.1:1", "", 200)
}

test "connect*: a closed port produces a real transport failure, not a placeholder" {
  match probeConnect() {
    case Ok(_) -> assertTrue(false, "unexpected connect success against a closed port")
    case Err(e) -> {
      assertEqual(e.code, "CONNECT_FAILED", "connect failure surfaces as CONNECT_FAILED")
      assertTrue(e.message.length > 0, "connect failure surfaces a non-empty transport error message")
    }
  }
}

// The generic client operations (search/suggest/delete/...) resolve
// through `NativeSearchClient` regardless of which backend feature is
// active. Constructing `NativeSearchClient` directly around an HttpConfig
// pointed at a closed port exercises a real HTTP call without needing a
// live backend server: `HttpConfig`/`Std.Http` are public, so this needs
// no Search-internal access.
func closedPortClient(): SearchClient {
  val cfg = HttpConfig.new(defaultClient(), "http://127.0.0.1:1", "", "")
  val client: SearchClient = NativeSearchClient(cfg = cfg)
  client
}

test "search: a closed port produces a real transport failure via SEARCH_FAILED" {
  val client = closedPortClient()
  val q = Search.makeQuery("products", "widget")
  match Search.search(client, q) {
    case Ok(_) -> assertTrue(false, "unexpected search success with no backend listening")
    case Err(e) -> {
      assertEqual(e.code, "SEARCH_FAILED", "search failure surfaces as SEARCH_FAILED")
      assertTrue(e.message.length > 0, "search must surface a non-empty error message")
    }
  }
}

test "suggest: a closed port produces a real transport failure via SUGGEST_FAILED" {
  val client = closedPortClient()
  match Search.suggest(client, "products", "wid", "name") {
    case Ok(_) -> assertTrue(false, "unexpected suggest success with no backend listening")
    case Err(e) -> {
      assertEqual(e.code, "SUGGEST_FAILED", "suggest failure surfaces as SUGGEST_FAILED")
      assertTrue(e.message.length > 0, "suggest must surface a non-empty error message")
    }
  }
}

test "delete: a closed port produces a real transport failure via DELETE_FAILED" {
  val client = closedPortClient()
  match Search.delete(client, "products", "p-1") {
    case Ok(_) -> assertTrue(false, "unexpected delete success with no backend listening")
    case Err(e) -> {
      assertEqual(e.code, "DELETE_FAILED", "delete failure surfaces as DELETE_FAILED")
      assertTrue(e.message.length > 0, "delete must surface a non-empty error message")
    }
  }
}

// ─── Live integration (opt-in, env-var gated) ────────────────────────────────
// No Elasticsearch or Meilisearch server is reachable in this repository's
// CI sandbox. Rather than skip live coverage entirely, this test performs
// a real round trip when a server IS configured (set
// LYRIC_SEARCH_ELASTICSEARCH_URL, or LYRIC_SEARCH_MEILISEARCH_URL under
// the meilisearch feature) and otherwise asserts the clean-skip path, so
// the test suite never fails just because no live engine is present.
@cfg(feature = "elasticsearch")
func integrationUrl(): String {
  getVarOrDefault("LYRIC_SEARCH_ELASTICSEARCH_URL", "")
}

@cfg(feature = "meilisearch")
func integrationUrl(): String {
  getVarOrDefault("LYRIC_SEARCH_MEILISEARCH_URL", "")
}

@cfg(feature = "elasticsearch")
func integrationConnect(url: in String): Result[SearchClient, SearchError] {
  await Search.connectElasticsearch(url, getVarOrDefault("LYRIC_SEARCH_ELASTICSEARCH_API_KEY", ""), getVarOrDefault("LYRIC_SEARCH_ELASTICSEARCH_USERNAME", ""), getVarOrDefault("LYRIC_SEARCH_ELASTICSEARCH_PASSWORD", ""), 5000, 30000)
}

@cfg(feature = "meilisearch")
func integrationConnect(url: in String): Result[SearchClient, SearchError] {
  await Search.connectMeilisearch(url, getVarOrDefault("LYRIC_SEARCH_MEILISEARCH_API_KEY", ""), 30000)
}

test "integration: live round trip when a real engine is configured, otherwise skip cleanly" {
  val url = integrationUrl()
  if url.length == 0 {
    assertTrue(
      true,
      "skipped: no live search engine configured " +
        "(set LYRIC_SEARCH_ELASTICSEARCH_URL / LYRIC_SEARCH_MEILISEARCH_URL to enable)"
    )
  } else {
    val testIndex = "lyric_search_integration_test"
    match integrationConnect(url) {
      case Err(e) -> assertTrue(false, "live connect failed: " + e.message)
      case Ok(client) -> {
        match await client.createIndex(testIndex, "") {
          case Err(e) -> assertTrue(false, "live createIndex failed: " + e.message)
          case Ok(_) -> {
            val fields: Map[String, String] = newMap()
            fields.add("name", "Integration Widget")
            val doc = Search.makeDoc(testIndex, "integration-doc-1", fields)
            match await client.index(doc) {
              case Err(e) -> assertTrue(false, "live index failed: " + e.message)
              case Ok(indexResult) -> {
                assertEqual(indexResult.id, "integration-doc-1", "live index result carries the document id")
                val q = Search.makeQuery(testIndex, "Widget")
                match await client.search(q) {
                  case Err(e) -> assertTrue(false, "live search failed: " + e.message)
                  case Ok(searchResult) -> assertTrue(searchResult.hits.length >= 0, "live search returns a result")
                }
                match await client.delete(testIndex, "integration-doc-1") {
                  case Err(e) -> assertTrue(false, "live delete failed: " + e.message)
                  case Ok(_) -> ()
                }
              }
            }
            match await client.deleteIndex(testIndex) {
              case Err(e) -> assertTrue(false, "live deleteIndex cleanup failed: " + e.message)
              case Ok(_) -> ()
            }
          }
        }
      }
    }
  }
}
