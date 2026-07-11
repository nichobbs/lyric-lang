//! Search — Elasticsearch backend (feature = "elasticsearch").
//!
//! Implements every `SearchClient` operation against a real Elasticsearch
//! HTTP API using `Std.Http` / `Std.Rest` / `Std.Json` — no native SDK
//! binding.  See lyric-search/README.md "Platform parity" for why the
//! earlier `extern package Elastic.Clients.Elasticsearch { ... }` approach
//! (which never resolved to a real FFI call, see issue #5324) was replaced
//! by pure-Lyric HTTP + JSON (issue #5408).
//!
//! Query/filter/sort mapping:
//!   - `SearchQuery.query` (non-empty)  -> `multi_match` clause across
//!     every field (`fields: ["*"]`) — plain-text matching, not
//!     Elasticsearch's Lucene-derived `query_string` mini-language
//!     (#5589; `query_string` let caller-supplied text carry query
//!     syntax — field scoping, wildcards, regex — into the query parser)
//!   - `SearchQuery.query` (empty)      -> `match_all`
//!   - `SearchFilter.operator = "eq"`        -> `term`
//!   - `SearchFilter.operator = "gt"/"gte"/"lt"/"lte"` -> `range`
//!   - `SearchFilter.operator = "contains"`  -> `match`
//!   - `SortField`                       -> `{"field": {"order": "asc"|"desc"}}`
//!   - `suggest`                         -> `match_phrase_prefix` on `field`
//!     (the simplest query type that gives prefix-style autocomplete without
//!     requiring a dedicated `completion` field mapping on the index)
//!
//! This is the same package as `search.l` (`Search`) — see
//! docs/19-multi-file-packages.md; shared helpers (`pathEscape`,
//! `toSearchError`, `sendRequest`, `readJsonBody`, `jsonScalarToString`,
//! `HttpConfig`, ...) are defined there and used here without an import.
@cfg(feature = "elasticsearch")
package Search

import Std.Core
import Std.Collections
import Std.Iter
import Std.Errors
import Std.Http
import Std.Json
import Std.Encoding

// ─── Auth ─────────────────────────────────────────────────────────────────────
// Returns (headerName, headerValue) for the "Authorization" header, or
// ("", "") for no auth. Modeled as two Strings rather than `Std.Rest.RestAuth`
// because this package cannot depend on `Std.Rest` — see search.l's
// `HttpConfig` doc comment for why.
func esAuthHeader(apiKey: in String, username: in String, password: in String): String {
  if apiKey.length > 0 {
    return "ApiKey " + apiKey
  }
  if username.length > 0 {
    val raw = username + ":" + password
    val credentials = encodeBase64(encodeUtf8(raw))
    return "Basic " + credentials
  }
  return ""
}

// ─── Connect ──────────────────────────────────────────────────────────────────
/// Build an HttpConfig for `url` and probe cluster reachability with
/// `GET /`.  `connectTimeoutMs` / `requestTimeoutMs` are accepted for
/// interface parity with the old kernel signature; per-request timeouts
/// are not yet threaded through `Std.Http` (tracked as a `Std.Http` gap,
/// not a `Search`-specific one).
pub async func backendConnectElasticsearch(
  url: in String,
  apiKey: in String,
  username: in String,
  password: in String,
  connectTimeoutMs: in Int,
  requestTimeoutMs: in Int,
): Result[HttpConfig, SearchError]
  requires: url.length > 0
{
  val authHeader = esAuthHeader(apiKey, username, password)
  val cfg = HttpConfig(
    client = defaultClient(),
    baseUrl = url,
    authHeaderName = "Authorization",
    authHeaderValue = authHeader
  )
  val probeCfg = if authHeader.length > 0 {
    cfg
  } else {
    HttpConfig(client = cfg.client, baseUrl = cfg.baseUrl, authHeaderName = "", authHeaderValue = "")
  }
  val checked = sendRequest(probeCfg, GET, "/", None, "CONNECT_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> return Ok(value = probeCfg)
  }
}

// ─── JSON body construction ───────────────────────────────────────────────────
pub func esFieldsToJsonObject(fields: in Map[String, String]): String {
  var body = "{"
  var first = true
  val entries = mapEntries(fields)
  for entry in entries {
    if not first {
      body = body + ","
    }
    body = body + encodeString(entry.key) + ":" + encodeString(entry.value)
    first = false
  }
  return body + "}"
}

// `multi_match` (not `query_string`): `query_string` parses its input as
// Elasticsearch's Lucene-derived mini-language — operators, field
// prefixes, wildcards, regex, proximity/boost syntax — so caller-supplied
// search text reaches the query parser as *syntax*, not plain terms. That
// is both a query-injection surface (a user can scope/boost/exclude
// arbitrary fields the UI never intended to expose) and a DoS surface
// (wildcard/regex terms are expensive to evaluate). `multi_match` treats
// the whole input as plain text tokens to match — no operators are parsed
// — while still searching across every field (`"fields":["*"]`), matching
// `query_string`'s previous "search everything" behaviour without its
// syntax surface (#5589).
pub func esQueryClause(q: in String): String {
  if q.length == 0 {
    return "{\"match_all\":{}}"
  }
  return "{\"multi_match\":{\"query\":" + encodeString(q) + ",\"fields\":[\"*\"]}}"
}

pub func esFilterClause(f: in SearchFilter): String {
  match f.operator {
    case "gt" -> "{\"range\":{" + encodeString(f.field) + ":{\"gt\":" + encodeString(f.value) + "}}}"
    case "gte" -> "{\"range\":{" + encodeString(f.field) + ":{\"gte\":" + encodeString(f.value) + "}}}"
    case "lt" -> "{\"range\":{" + encodeString(f.field) + ":{\"lt\":" + encodeString(f.value) + "}}}"
    case "lte" -> "{\"range\":{" + encodeString(f.field) + ":{\"lte\":" + encodeString(f.value) + "}}}"
    case "contains" -> "{\"match\":{" + encodeString(f.field) + ":" + encodeString(f.value) + "}}"
    case _ -> "{\"term\":{" + encodeString(f.field) + ":" + encodeString(f.value) + "}}"
  }
}

func esSortClause(s: in SortField): String {
  val order = if s.descending { "desc" } else { "asc" }
  return "{" + encodeString(s.field) + ":{\"order\":\"" + order + "\"}}"
}

func esHighlightFieldsObject(fields: in slice[String]): String {
  var body = "{"
  var first = true
  for f in fields {
    if not first {
      body = body + ","
    }
    body = body + encodeString(f) + ":{}"
    first = false
  }
  return body + "}"
}

pub func esBuildSearchBody(query: in SearchQuery): String {
  var filterArr = "["
  var first = true
  for f in query.filters {
    if not first {
      filterArr = filterArr + ","
    }
    filterArr = filterArr + esFilterClause(f)
    first = false
  }
  filterArr = filterArr + "]"

  var body = "{\"from\":" + query.from.toString() + ",\"size\":" + query.size.toString() +
    ",\"query\":{\"bool\":{\"must\":[" +
    esQueryClause(query.query) +
    "],\"filter\":" +
    filterArr +
    "}}"

  if query.sort.length > 0 {
    var sortArr = "["
    first = true
    for s in query.sort {
      if not first {
        sortArr = sortArr + ","
      }
      sortArr = sortArr + esSortClause(s)
      first = false
    }
    body = body + ",\"sort\":" + sortArr + "]"
  }

  if query.highlightFields.length > 0 {
    body = body + ",\"highlight\":{\"fields\":" + esHighlightFieldsObject(query.highlightFields) + "}"
  }

  return body + "}"
}

// ─── Response parsing ─────────────────────────────────────────────────────────
pub func esParseIndexResult(elem: in JsonElement): IndexResult {
  var id: String = ""
  var version: Long = 0i64
  var status: String = "created"
  match tryGetProperty(elem, "_id") {
    case Some(v) -> {
      id = getString(v)
    }
    case None -> ()
  }
  match tryGetProperty(elem, "_version") {
    case Some(v) -> match tryGetLong(v) { case Some(n) -> { version = n }; case None -> () }
    case None -> ()
  }
  match tryGetProperty(elem, "result") {
    case Some(v) -> {
      status = getString(v)
    }
    case None -> ()
  }
  return IndexResult(id = id, version = version, status = status)
}

func esParseBulkResponse(root: in JsonElement): slice[IndexResult] {
  var results: slice[IndexResult] = []
  match tryGetProperty(root, "items") {
    case Some(arr) -> {
      var en = enumerateArray(arr)
      while arrayMoveNext(en) {
        val itemElem = arrayCurrent(en)
        var itemCursor = enumerateObject(itemElem)
        if objectMoveNext(itemCursor) {
          val prop = objectCurrent(itemCursor)
          results = concat(results, [esParseIndexResult(propertyValue(prop))])
        }
      }
    }
    case None -> ()
  }
  return results
}

func esParseHighlight(field: in String, arr: in JsonElement): Highlight {
  var fragments: slice[String] = []
  var en = enumerateArray(arr)
  while arrayMoveNext(en) {
    val elem = arrayCurrent(en)
    if valueKind(elem) == 3 {
      fragments = concat(fragments, [getString(elem)])
    }
  }
  return Highlight(field = field, fragments = fragments)
}

func esParseHit(elem: in JsonElement): SearchHit {
  var id: String = ""
  var index: String = ""
  var score: Double = 0.0
  var source: Map[String, String] = newMap()
  var highlights: slice[Highlight] = []
  match tryGetProperty(elem, "_id") {
    case Some(v) -> {
      id = getString(v)
    }
    case None -> ()
  }
  match tryGetProperty(elem, "_index") {
    case Some(v) -> {
      index = getString(v)
    }
    case None -> ()
  }
  match tryGetProperty(elem, "_score") {
    case Some(v) -> if valueKind(v) == 4 { score = getDouble(v) }
    case None -> ()
  }
  match tryGetProperty(elem, "_source") {
    case Some(obj) -> {
      var en = enumerateObject(obj)
      while objectMoveNext(en) {
        val prop = objectCurrent(en)
        source.add(propertyName(prop), jsonScalarToString(propertyValue(prop)))
      }
    }
    case None -> ()
  }
  match tryGetProperty(elem, "highlight") {
    case Some(obj) -> {
      var en = enumerateObject(obj)
      while objectMoveNext(en) {
        val prop = objectCurrent(en)
        highlights = concat(highlights, [esParseHighlight(propertyName(prop), propertyValue(prop))])
      }
    }
    case None -> ()
  }
  return SearchHit(id = id, index = index, score = score, highlights = highlights, source = source)
}

pub func esParseSearchResponse(root: in JsonElement): SearchResult {
  var total: Long = 0i64
  var tookMs: Int = 0
  var hits: slice[SearchHit] = []
  match tryGetProperty(root, "took") {
    case Some(v) -> match tryGetInt(v) { case Some(n) -> { tookMs = n }; case None -> () }
    case None -> ()
  }
  match tryGetProperty(root, "hits") {
    case Some(hitsObj) -> {
      match tryGetProperty(hitsObj, "total") {
        case Some(totalObj) -> match tryGetProperty(totalObj, "value") { case Some(v) -> match tryGetLong(v) { case Some(n) -> { total = n }; case None -> () }; case None -> () }
        case None -> ()
      }
      match tryGetProperty(hitsObj, "hits") {
        case Some(arr) -> {
          var en = enumerateArray(arr)
          while arrayMoveNext(en) {
            hits = concat(hits, [esParseHit(arrayCurrent(en))])
          }
        }
        case None -> ()
      }
    }
    case None -> ()
  }
  return SearchResult(total = total, hits = hits, tookMs = tookMs, scrollId = None)
}

pub func esParseSuggestResponse(root: in JsonElement, field: in String): SuggestResult {
  var tookMs: Int = 0
  var suggestions: slice[String] = []
  match tryGetProperty(root, "took") {
    case Some(v) -> match tryGetInt(v) { case Some(n) -> { tookMs = n }; case None -> () }
    case None -> ()
  }
  match tryGetProperty(root, "hits") {
    case Some(hitsObj) -> match tryGetProperty(hitsObj, "hits") { case Some(arr) -> { var en = enumerateArray(arr); while arrayMoveNext(en) { val hitElem = arrayCurrent(en); match tryGetProperty(hitElem, "_source") { case Some(source) -> match tryGetProperty(source, field) { case Some(v) -> { suggestions = concat(suggestions, [jsonScalarToString(v)]) }; case None -> () }; case None -> () } } }; case None -> () }
    case None -> ()
  }
  return SuggestResult(suggestions = suggestions, tookMs = tookMs)
}

// ─── Operations ───────────────────────────────────────────────────────────────
pub async func backendIndex(cfg: in HttpConfig, doc: in SearchDocument): Result[IndexResult, SearchError] {
  val path = "/" + pathEscape(doc.index) + "/_doc/" + pathEscape(doc.id)
  val checked = sendRequest(cfg, PUT, path, Some(value = esFieldsToJsonObject(doc.fields)), "INDEX_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "INDEX_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          defer {
            disposeJson(jdoc)
          }
          return Ok(value = esParseIndexResult(rootElement(jdoc)))
        }
      }
    }
  }
}

pub async func backendIndexBatch(
  cfg: in HttpConfig, docs: in slice[SearchDocument]
): Result[slice[IndexResult], SearchError] {
  if docs.length == 0 {
    return Ok(value = [])
  }
  var body = ""
  for d in docs {
    body = body + "{\"index\":{\"_index\":" + encodeString(d.index) + ",\"_id\":" + encodeString(d.id) + "}}\n"
    body = body + esFieldsToJsonObject(d.fields) + "\n"
  }
  val path = "/_bulk"
  val checked = sendRequest(cfg, POST, path, Some(value = body), "BATCH_INDEX_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "BATCH_INDEX_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          defer {
            disposeJson(jdoc)
          }
          return Ok(value = esParseBulkResponse(rootElement(jdoc)))
        }
      }
    }
  }
}

pub async func backendSearch(cfg: in HttpConfig, query: in SearchQuery): Result[SearchResult, SearchError] {
  val path = "/" + pathEscape(query.index) + "/_search"
  val checked = sendRequest(cfg, POST, path, Some(value = esBuildSearchBody(query)), "SEARCH_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "SEARCH_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          defer {
            disposeJson(jdoc)
          }
          return Ok(value = esParseSearchResponse(rootElement(jdoc)))
        }
      }
    }
  }
}

pub async func backendSuggest(
  cfg: in HttpConfig, index: in String, text: in String, field: in String, size: in Int
): Result[SuggestResult, SearchError] {
  val path = "/" + pathEscape(index) + "/_search"
  val body = "{\"size\":" + size.toString() + ",\"query\":{\"match_phrase_prefix\":{" + encodeString(field) + ":" +
    encodeString(text) +
    "}}}"
  val checked = sendRequest(cfg, POST, path, Some(value = body), "SUGGEST_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "SUGGEST_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          defer {
            disposeJson(jdoc)
          }
          return Ok(value = esParseSuggestResponse(rootElement(jdoc), field))
        }
      }
    }
  }
}

pub async func backendDelete(cfg: in HttpConfig, index: in String, id: in String): Result[Unit, SearchError] {
  val path = "/" + pathEscape(index) + "/_doc/" + pathEscape(id)
  val checked = sendRequest(cfg, DELETE, path, None, "DELETE_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> return Ok(value = ())
  }
}

pub async func backendDeleteIndex(cfg: in HttpConfig, index: in String): Result[Unit, SearchError] {
  val path = "/" + pathEscape(index)
  val checked = sendRequest(cfg, DELETE, path, None, "DELETE_INDEX_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> return Ok(value = ())
  }
}

pub async func backendExists(cfg: in HttpConfig, index: in String, id: in String): Result[Bool, SearchError] {
  val path = "/" + pathEscape(index) + "/_doc/" + pathEscape(id)
  val sent = sendRequestRaw(cfg, GET, path, "EXISTS_FAILED")
  match sent {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val status = HttpResponse.statusCode(response)
      if status == 200 {
        return Ok(value = true)
      }
      if status == 404 {
        return Ok(value = false)
      }
      return Err(
        error = SearchError(
          message = "unexpected status " + status.toString() + " from Elasticsearch exists check",
          code = "EXISTS_FAILED",
          statusCode = status
        )
      )
    }
  }
}

pub async func backendCreateIndex(
  cfg: in HttpConfig, index: in String, mappingJson: in String
): Result[Unit, SearchError] {
  val path = "/" + pathEscape(index)
  val body = if mappingJson.length == 0 { "{}" } else { mappingJson }
  val checked = sendRequest(cfg, PUT, path, Some(value = body), "CREATE_INDEX_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> return Ok(value = ())
  }
}
