//! Search — Meilisearch backend (feature = "meilisearch").
//!
//! Implements every `SearchClient` operation against a real Meilisearch
//! HTTP API using `Std.Http` / `Std.Json` — no native SDK binding.  See
//! lyric-search/README.md "Platform parity" for why the earlier `extern
//! package MeilisearchDotnet { ... }` approach (which never resolved to a
//! real FFI call, see issue #5324) was replaced by pure-Lyric HTTP + JSON
//! (issue #5408).
//!
//! Meilisearch's document-mutation endpoints (`documents`, index creation,
//! index/document deletion, settings updates) are asynchronous: they
//! enqueue a task and return `{"taskUid": N, "status": "enqueued", ...}`
//! immediately. `msAwaitTask` polls `GET /tasks/{uid}` (50ms between polls,
//! up to 1s total) so callers get a result that reflects the actual
//! outcome rather than a meaningless "enqueued" for every call. If the task
//! is still processing after the wait budget, the enqueued status is
//! reported rather than blocking indefinitely — Meilisearch tasks for
//! single-document/small-batch operations normally complete in
//! low-single-digit milliseconds, so this only bites under host load or on
//! very large batches.
//!
//! Every document this client indexes carries an explicit `"id"` field
//! (`msDocToJsonObject`), so `id` is the primary key Meilisearch indexes
//! are created with (`backendCreateIndex`) and the field this client reads
//! back out of search hits (`msParseHit`).
//!
//! Query/filter/sort mapping:
//!   - `search`/`suggest`      -> `q` (Meilisearch's prefix-aware full-text
//!     search already matches `text` as a prefix natively; no separate
//!     "suggest" endpoint is needed)
//!   - `SearchFilter.operator = "eq"`        -> `field = 'value'`
//!   - `SearchFilter.operator = "gt"/"gte"/"lt"/"lte"` -> `field > 'value'` etc
//!   - `SearchFilter.operator = "contains"`  -> `field CONTAINS 'value'`
//!     (combined with `AND`; requires the field to be in the index's
//!     `filterableAttributes`, or Meilisearch returns a 400 — surfaced as
//!     the usual transport `BadStatus` error)
//!   - `SortField`             -> `"field:asc"` / `"field:desc"` string
//!     (requires the field to be in `sortableAttributes`)
//!   - `highlightFields`       -> `attributesToHighlight`; each hit's
//!     `_formatted.<field>` string becomes that field's single Highlight
//!     fragment (Meilisearch returns one highlighted string per attribute,
//!     not a fragment list like Elasticsearch)
//!
//! This is the same package as `search.l` (`Search`) — see
//! docs/19-multi-file-packages.md; shared helpers (`pathEscape`,
//! `toSearchError`, `sendRequest`, `readJsonBody`, `jsonScalarToString`,
//! `HttpConfig`, ...) are defined there and used here without an import.
@cfg(feature = "meilisearch")
package Search

import Std.Core
import Std.Collections
import Std.Iter
import Std.Errors
import Std.Http
import Std.Json
import Std.Task
import Std.Char

val msTaskPollIntervalMs: Int = 50

val msTaskMaxPolls: Int = 20

// ─── Connect ──────────────────────────────────────────────────────────────────
/// Build an HttpConfig for `url` and probe reachability with
/// `GET /health`.
pub async func backendConnectMeilisearch(
  url: in String, apiKey: in String, connectTimeoutMs: in Int
): Result[HttpConfig, SearchError]
  requires: url.length > 0
{
  val authHeader = if apiKey.length > 0 { "Bearer " + apiKey } else { "" }
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
  val checked = sendRequest(probeCfg, GET, "/health", None, "CONNECT_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> return Ok(value = probeCfg)
  }
}

// ─── JSON body construction ───────────────────────────────────────────────────
pub func msDocToJsonObject(doc: in SearchDocument): String {
  var body = "{\"id\":" + encodeString(doc.id)
  val entries = mapEntries(doc.fields)
  for entry in entries {
    body = body + "," + encodeString(entry.key) + ":" + encodeString(entry.value)
  }
  return body + "}"
}

// Escapes both `\` and `'` (backslash first, so an already-escaped `\'`
// produced by this function is never re-escaped): Meilisearch's filter
// grammar quotes string values in single or double quotes with backslash
// escaping for embedded quote/backslash characters, the same convention
// as shell/SQL string literals (#5585). Scanning the *original*
// characters one at a time (not re-scanning the growing `escaped`
// accumulator) means checking backslash before quote per character is
// sufficient — there is no way for the two checks to interact within a
// single pass.
pub func msQuote(v: in String): String {
  var escaped = ""
  var i = 0
  while i < v.length {
    val c = v[i]
    if c == '\\' {
      escaped = escaped + "\\\\"
    } else if c == '\'' {
      escaped = escaped + "\\'"
    } else {
      escaped = escaped + c.toString()
    }
    i = i + 1
  }
  return "'" + escaped + "'"
}

// Meilisearch's filter grammar has no quoting/escaping mechanism for
// *attribute names* (only for string values, via `msQuote` above) — an
// attribute name is spliced into the filter expression as a bare,
// unquoted token. A caller-supplied `field` is therefore restricted to a
// safe identifier charset (letters, digits, `_`, `.`, `-` — covering
// ordinary attribute names and Meilisearch's dotted nested-attribute
// paths) before it is ever concatenated into a filter clause (#5585).
func msIsSafeFieldName(field: in String): Bool {
  if field.length == 0 {
    return false
  }
  var i = 0
  while i < field.length {
    val c = field[i]
    if not (isAsciiLetterOrDigit(c) or c == '_' or c == '.' or c == '-') {
      return false
    }
    i = i + 1
  }
  return true
}

// A field name outside the safe charset is never spliced into the filter
// expression as-is. There is no field-name quoting to fall back to (see
// `msIsSafeFieldName`'s doc comment), so the only safe substitute is a
// placeholder attribute name that can never exist in a real index:
// Meilisearch rejects a filter referencing an unknown/non-filterable
// attribute with an HTTP 400, which surfaces through the normal
// `SEARCH_FAILED`/`BATCH_INDEX_FAILED` transport-error path — the request
// fails closed instead of splicing attacker-controlled filter syntax.
func msSafeField(field: in String): String {
  if msIsSafeFieldName(field) {
    field
  } else {
    "__lyric_rejected_unsafe_field_name__"
  }
}

pub func msFilterExpr(f: in SearchFilter): String {
  val field = msSafeField(f.field)
  match f.operator {
    case "gt" -> field + " > " + msQuote(f.value)
    case "gte" -> field + " >= " + msQuote(f.value)
    case "lt" -> field + " < " + msQuote(f.value)
    case "lte" -> field + " <= " + msQuote(f.value)
    case "contains" -> field + " CONTAINS " + msQuote(f.value)
    case _ -> field + " = " + msQuote(f.value)
  }
}

func msBuildFilter(filters: in slice[SearchFilter]): String {
  var expr = ""
  var first = true
  for f in filters {
    if not first {
      expr = expr + " AND "
    }
    expr = expr + msFilterExpr(f)
    first = false
  }
  return expr
}

pub func msBuildSearchBody(query: in SearchQuery, includeRankingScore: in Bool): String {
  var body = "{\"q\":" + encodeString(query.query) + ",\"offset\":" + query.from.toString() + ",\"limit\":" +
    query.size.toString()

  if query.filters.length > 0 {
    body = body + ",\"filter\":" + encodeString(msBuildFilter(query.filters))
  }

  if query.sort.length > 0 {
    var sortArr = "["
    var first = true
    for s in query.sort {
      if not first {
        sortArr = sortArr + ","
      }
      val direction = if s.descending { "desc" } else { "asc" }
      sortArr = sortArr + encodeString(s.field + ":" + direction)
      first = false
    }
    body = body + ",\"sort\":" + sortArr + "]"
  }

  if query.highlightFields.length > 0 {
    var attrArr = "["
    var first = true
    for f in query.highlightFields {
      if not first {
        attrArr = attrArr + ","
      }
      attrArr = attrArr + encodeString(f)
      first = false
    }
    body = body + ",\"attributesToHighlight\":" + attrArr + "]"
  }

  if includeRankingScore {
    body = body + ",\"showRankingScore\":true"
  }

  return body + "}"
}

// ─── Response parsing ─────────────────────────────────────────────────────────
func msIsReservedKey(key: in String): Bool {
  return key == "_formatted" or key == "_rankingScore"
}

func msParseHit(elem: in JsonElement, index: in String): SearchHit {
  var id: String = ""
  var score: Double = 0.0
  var source: Map[String, String] = newMap()
  var highlights: slice[Highlight] = []
  var en = enumerateObject(elem)
  while objectMoveNext(en) {
    val prop = objectCurrent(en)
    val key = propertyName(prop)
    if key == "id" {
      id = jsonScalarToString(propertyValue(prop))
    }
    if not msIsReservedKey(key) {
      source.add(key, jsonScalarToString(propertyValue(prop)))
    }
  }
  match tryGetProperty(elem, "_rankingScore") {
    case Some(v) -> if valueKind(v) == 4 { score = getDouble(v) }
    case None -> ()
  }
  match tryGetProperty(elem, "_formatted") {
    case Some(obj) -> {
      var fen = enumerateObject(obj)
      while objectMoveNext(fen) {
        val fprop = objectCurrent(fen)
        val hfield = propertyName(fprop)
        val hvalue = propertyValue(fprop)
        if valueKind(hvalue) == 3 {
          highlights = concat(highlights, [Highlight(field = hfield, fragments = [getString(hvalue)])])
        }
      }
    }
    case None -> ()
  }
  return SearchHit(id = id, index = index, score = score, highlights = highlights, source = source)
}

pub func msParseSearchResponse(root: in JsonElement, index: in String): SearchResult {
  var total: Long = 0i64
  var tookMs: Int = 0
  var hits: slice[SearchHit] = []
  match tryGetProperty(root, "processingTimeMs") {
    case Some(v) -> match tryGetInt(v) { case Some(n) -> { tookMs = n }; case None -> () }
    case None -> ()
  }
  match tryGetProperty(root, "estimatedTotalHits") {
    case Some(v) -> match tryGetLong(v) { case Some(n) -> { total = n }; case None -> () }
    case None -> ()
  }
  if total == 0i64 {
    match tryGetProperty(root, "totalHits") {
      case Some(v) -> match tryGetLong(v) { case Some(n) -> { total = n }; case None -> () }
      case None -> ()
    }
  }
  match tryGetProperty(root, "hits") {
    case Some(arr) -> {
      var en = enumerateArray(arr)
      while arrayMoveNext(en) {
        hits = concat(hits, [msParseHit(arrayCurrent(en), index)])
      }
    }
    case None -> ()
  }
  return SearchResult(total = total, hits = hits, tookMs = tookMs, scrollId = None)
}

func msTaskUid(root: in JsonElement): Int {
  match tryGetProperty(root, "taskUid") {
    case Some(v) -> match tryGetInt(v) { case Some(n) -> n; case None -> 0 }
    case None -> 0
  }
}

/// Poll `GET /tasks/{taskUid}` until it reaches a terminal state
/// ("succeeded" / "failed"), or the wait budget is exhausted (in which
/// case "enqueued" is returned — see the file header). A "failed" task
/// becomes `Err`, carrying Meilisearch's own error message and tagged with
/// `code` (the calling operation's SearchError code, e.g. "INDEX_FAILED").
async func msAwaitTask(cfg: in HttpConfig, taskUid: in Int, code: in String): Result[String, SearchError] {
  val path = "/tasks/" + taskUid.toString()
  var attempt = 0
  while attempt < msTaskMaxPolls {
    val checked = sendRequest(cfg, GET, path, None, code)
    match checked {
      case Err(e) -> return Err(error = e)
      case Ok(response) -> {
        val parsed = await readJsonBody(response, code)
        match parsed {
          case Err(e) -> return Err(error = e)
          case Ok(jdoc) -> {
            defer {
              disposeJson(jdoc)
            }
            val root = rootElement(jdoc)
            var status: String = "enqueued"
            match tryGetProperty(root, "status") {
              case Some(v) -> {
                status = getString(v)
              }
              case None -> ()
            }
            if status == "succeeded" {
              return Ok(value = status)
            }
            if status == "failed" {
              var reason = "Meilisearch task " + taskUid.toString() + " failed"
              match tryGetProperty(root, "error") {
                case Some(errObj) -> match tryGetProperty(errObj, "message") { case Some(mv) -> { reason = getString(mv) }; case None -> () }
                case None -> ()
              }
              return Err(error = SearchError(message = reason, code = code, statusCode = 0))
            }
          }
        }
      }
    }
    await delay(msTaskPollIntervalMs)
    attempt = attempt + 1
  }
  return Ok(value = "enqueued")
}

// ─── Operations ───────────────────────────────────────────────────────────────
pub async func backendIndex(cfg: in HttpConfig, doc: in SearchDocument): Result[IndexResult, SearchError] {
  val path = "/indexes/" + pathEscape(doc.index) + "/documents"
  val checked = sendRequest(cfg, POST, path, Some(value = "[" + msDocToJsonObject(doc) + "]"), "INDEX_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "INDEX_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          val taskUid = msTaskUid(rootElement(jdoc))
          disposeJson(jdoc)
          val awaited = await msAwaitTask(cfg, taskUid, "INDEX_FAILED")
          match awaited {
            case Err(e) -> return Err(error = e)
            case Ok(status) -> {
              val resultStatus = if status == "succeeded" { "created" } else { "enqueued" }
              return Ok(value = IndexResult(id = doc.id, version = taskUid.toLong(), status = resultStatus))
            }
          }
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
  val index = docs[0].index
  for d in docs {
    if d.index != index {
      return Err(
        error = SearchError(
          message = "Meilisearch indexBatch requires every document to share the same index (got '" + index +
            "' and '" +
            d.index +
            "'); Meilisearch's documents endpoint is index-scoped",
          code = "BATCH_INDEX_FAILED",
          statusCode = 0
        )
      )
    }
  }
  var body = "["
  var first = true
  for d in docs {
    if not first {
      body = body + ","
    }
    body = body + msDocToJsonObject(d)
    first = false
  }
  body = body + "]"
  val path = "/indexes/" + pathEscape(index) + "/documents"
  val checked = sendRequest(cfg, POST, path, Some(value = body), "BATCH_INDEX_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "BATCH_INDEX_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          val taskUid = msTaskUid(rootElement(jdoc))
          disposeJson(jdoc)
          val awaited = await msAwaitTask(cfg, taskUid, "BATCH_INDEX_FAILED")
          match awaited {
            case Err(e) -> return Err(error = e)
            case Ok(status) -> {
              val resultStatus = if status == "succeeded" { "created" } else { "enqueued" }
              var results: slice[IndexResult] = []
              for d in docs {
                results = concat(results, [IndexResult(id = d.id, version = taskUid.toLong(), status = resultStatus)])
              }
              return Ok(value = results)
            }
          }
        }
      }
    }
  }
}

pub async func backendSearch(cfg: in HttpConfig, query: in SearchQuery): Result[SearchResult, SearchError] {
  val path = "/indexes/" + pathEscape(query.index) + "/search"
  val checked = sendRequest(cfg, POST, path, Some(value = msBuildSearchBody(query, true)), "SEARCH_FAILED")
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
          return Ok(value = msParseSearchResponse(rootElement(jdoc), query.index))
        }
      }
    }
  }
}

pub async func backendSuggest(
  cfg: in HttpConfig, index: in String, text: in String, field: in String, size: in Int
): Result[SuggestResult, SearchError] {
  val path = "/indexes/" + pathEscape(index) + "/search"
  val body = "{\"q\":" + encodeString(text) + ",\"limit\":" + size.toString() + "}"
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
          var tookMs: Int = 0
          var suggestions: slice[String] = []
          val root = rootElement(jdoc)
          match tryGetProperty(root, "processingTimeMs") {
            case Some(v) -> match tryGetInt(v) { case Some(n) -> { tookMs = n }; case None -> () }
            case None -> ()
          }
          match tryGetProperty(root, "hits") {
            case Some(arr) -> {
              var en = enumerateArray(arr)
              while arrayMoveNext(en) {
                val hitElem = arrayCurrent(en)
                match tryGetProperty(hitElem, field) {
                  case Some(v) -> {
                    suggestions = concat(suggestions, [jsonScalarToString(v)])
                  }
                  case None -> ()
                }
              }
            }
            case None -> ()
          }
          return Ok(value = SuggestResult(suggestions = suggestions, tookMs = tookMs))
        }
      }
    }
  }
}

pub async func backendDelete(cfg: in HttpConfig, index: in String, id: in String): Result[Unit, SearchError] {
  val path = "/indexes/" + pathEscape(index) + "/documents/" + pathEscape(id)
  val checked = sendRequest(cfg, DELETE, path, None, "DELETE_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "DELETE_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          val taskUid = msTaskUid(rootElement(jdoc))
          disposeJson(jdoc)
          val awaited = await msAwaitTask(cfg, taskUid, "DELETE_FAILED")
          match awaited {
            case Err(e) -> return Err(error = e)
            case Ok(_) -> return Ok(value = ())
          }
        }
      }
    }
  }
}

pub async func backendDeleteIndex(cfg: in HttpConfig, index: in String): Result[Unit, SearchError] {
  val path = "/indexes/" + pathEscape(index)
  val checked = sendRequest(cfg, DELETE, path, None, "DELETE_INDEX_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "DELETE_INDEX_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          val taskUid = msTaskUid(rootElement(jdoc))
          disposeJson(jdoc)
          val awaited = await msAwaitTask(cfg, taskUid, "DELETE_INDEX_FAILED")
          match awaited {
            case Err(e) -> return Err(error = e)
            case Ok(_) -> return Ok(value = ())
          }
        }
      }
    }
  }
}

pub async func backendExists(cfg: in HttpConfig, index: in String, id: in String): Result[Bool, SearchError] {
  val path = "/indexes/" + pathEscape(index) + "/documents/" + pathEscape(id)
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
          message = "unexpected status " + status.toString() + " from Meilisearch exists check",
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
  val path = "/indexes"
  val body = "{\"uid\":" + encodeString(index) + ",\"primaryKey\":\"id\"}"
  val checked = sendRequest(cfg, POST, path, Some(value = body), "CREATE_INDEX_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "CREATE_INDEX_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          val taskUid = msTaskUid(rootElement(jdoc))
          disposeJson(jdoc)
          val awaited = await msAwaitTask(cfg, taskUid, "CREATE_INDEX_FAILED")
          match awaited {
            case Err(e) -> return Err(error = e)
            case Ok(_) -> {
              if mappingJson.length == 0 {
                return Ok(value = ())
              }
              return await msApplySettings(cfg, index, mappingJson)
            }
          }
        }
      }
    }
  }
}

async func msApplySettings(cfg: in HttpConfig, index: in String, settingsJson: in String): Result[Unit, SearchError] {
  val path = "/indexes/" + pathEscape(index) + "/settings"
  val checked = sendRequest(cfg, PATCH, path, Some(value = settingsJson), "CREATE_INDEX_FAILED")
  match checked {
    case Err(e) -> return Err(error = e)
    case Ok(response) -> {
      val parsed = await readJsonBody(response, "CREATE_INDEX_FAILED")
      match parsed {
        case Err(e) -> return Err(error = e)
        case Ok(jdoc) -> {
          val taskUid = msTaskUid(rootElement(jdoc))
          disposeJson(jdoc)
          val awaited = await msAwaitTask(cfg, taskUid, "CREATE_INDEX_FAILED")
          match awaited {
            case Err(e) -> return Err(error = e)
            case Ok(_) -> return Ok(value = ())
          }
        }
      }
    }
  }
}
