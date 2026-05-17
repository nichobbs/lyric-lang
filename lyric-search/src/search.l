/// Search — search engine integration for Lyric applications.
///
/// Provides a `SearchClient` interface with Elasticsearch and Meilisearch
/// backends selectable at runtime via feature flags.  Both backends expose
/// the same API: index, batch-index, search, suggest, delete, and index
/// management.
///
/// Typical usage:
///
///   import Search
///   import Std.Collections
///
///   // Connect (backend selected by compile-time feature flag):
///   match Search.connect("elasticsearch") {
///     case Ok(client) ->
///       val doc = Search.makeDoc("products", "p-1", Map.of("name", "Widget"))
///       Search.index(client, doc)
///
///       val q = Search.makeQuery("products", "Widget")
///       match Search.search(client, q) {
///         case Ok(result) -> ...
///         case Err(e)     -> ...
///       }
///     case Err(e) -> ...
///   }
///
/// Runtime config env vars (LYRIC_CONFIG_SEARCH_CONNECTION_*):
///   LYRIC_CONFIG_SEARCH_CONNECTION_URL                — backend URL (required)
///   LYRIC_CONFIG_SEARCH_CONNECTION_INDEXPREFIX        — prefix for all index names (default: "")
///   LYRIC_CONFIG_SEARCH_CONNECTION_APIKEY             — API key (default: "")
///   LYRIC_CONFIG_SEARCH_CONNECTION_USERNAME           — HTTP basic username (default: "")
///   LYRIC_CONFIG_SEARCH_CONNECTION_PASSWORD           — HTTP basic password (default: "")
///   LYRIC_CONFIG_SEARCH_CONNECTION_CONNECTTIMEOUTMS   — connection timeout ms (default: 5000)
///   LYRIC_CONFIG_SEARCH_CONNECTION_REQUESTTIMEOUTMS   — request timeout ms (default: 30000)

@runtime_checked
package Search

import Std.Core
import Std.Collections
import Std.Json
import Search.Kernel.Net

// ─── Error type ───────────────────────────────────────────────────────────────

/// Error returned by SearchClient operations.
@stable(since="0.1")
pub record SearchError {
  message:    String
  code:       String
  statusCode: Int
}

// ─── Document model ───────────────────────────────────────────────────────────

/// A document to be indexed.  Field values are strings; callers should
/// JSON-encode complex values before storing them.
@stable(since="0.1")
pub record SearchDocument {
  id:     String
  index:  String
  fields: Map[String, String]
}

// ─── Result model ─────────────────────────────────────────────────────────────

/// A highlighted fragment for a single field.
@stable(since="0.1")
pub record Highlight {
  field:     String
  fragments: [String]
}

/// A single search hit.
@stable(since="0.1")
pub record SearchHit {
  id:         String
  index:      String
  score:      Float
  highlights: [Highlight]
  source:     Map[String, String]
}

/// Sorting specification for a single field.
@stable(since="0.1")
pub record SortField {
  field:      String
  descending: Bool
}

/// A filter clause applied to search queries.
/// `operator` is one of: "eq", "gt", "gte", "lt", "lte", "contains".
@stable(since="0.1")
pub record SearchFilter {
  field:    String
  value:    String
  operator: String
}

/// A full search request.
@stable(since="0.1")
pub record SearchQuery {
  index:           String
  query:           String
  filters:         [SearchFilter]
  from:            Int
  size:            Int
  sort:            [SortField]
  highlightFields: [String]
}

/// The result of a search operation.
@stable(since="0.1")
pub record SearchResult {
  total:    Long
  hits:     [SearchHit]
  tookMs:   Int
  scrollId: Option[String]
}

/// Autocomplete / type-ahead suggestions.
@stable(since="0.1")
pub record SuggestResult {
  suggestions: [String]
  tookMs:      Int
}

/// Result of an index or upsert operation.
@stable(since="0.1")
pub record IndexResult {
  id:      String
  version: Long
  result:  String   // "created", "updated", or "noop"
}

// ─── Client interface ─────────────────────────────────────────────────────────

/// Search engine client.  Obtain via `Search.connectElasticsearch()`,
/// `Search.connectMeilisearch()`, or the dispatching `Search.connect()`.
@stable(since="0.1")
pub interface SearchClient {
  /// Index a single document.
  func index(doc: in SearchDocument): Result[IndexResult, SearchError]
    requires: doc.index.length > 0
    requires: doc.id.length > 0

  /// Index a batch of documents in a single request.
  func indexBatch(docs: in [SearchDocument]): Result[[IndexResult], SearchError]

  /// Execute a search query and return matching hits.
  func search(query: in SearchQuery): Result[SearchResult, SearchError]
    requires: query.index.length > 0

  /// Return autocomplete suggestions for `text` on `field` in `index`.
  func suggest(index: in String, text: in String, field: in String, size: in Int): Result[SuggestResult, SearchError]
    requires: index.length > 0
    requires: field.length > 0
    requires: size > 0

  /// Delete a single document by ID.
  func delete(index: in String, id: in String): Result[Unit, SearchError]
    requires: index.length > 0
    requires: id.length > 0

  /// Delete an entire index.
  func deleteIndex(index: in String): Result[Unit, SearchError]
    requires: index.length > 0

  /// Return whether a document exists.
  func exists(index: in String, id: in String): Result[Bool, SearchError]
    requires: index.length > 0
    requires: id.length > 0

  /// Create an index with the given mapping JSON.
  func createIndex(index: in String, mappingJson: in String): Result[Unit, SearchError]
    requires: index.length > 0
}

// ─── Native client ────────────────────────────────────────────────────────────

/// Kernel-backed search client.  Obtain via the factory functions.
@stable(since="0.1")
pub record NativeSearchClient {
  clientHandle: Int
}

impl SearchClient for NativeSearchClient {
  func index(doc: in SearchDocument): Result[IndexResult, SearchError] {
    val docJson = serializeDoc(doc)
    match Search.Kernel.Net.index(clientHandle, docJson) {
      case Ok(json)  -> Ok(parseIndexResult(json))
      case Err(err)  -> Err(SearchError(message = err, code = "INDEX_FAILED", statusCode = 0))
    }
  }

  func indexBatch(docs: in [SearchDocument]): Result[[IndexResult], SearchError] {
    val docsJson = serializeDocList(docs)
    match Search.Kernel.Net.indexBatch(clientHandle, docsJson) {
      case Ok(json)  -> Ok(parseIndexResultList(json))
      case Err(err)  -> Err(SearchError(message = err, code = "BATCH_INDEX_FAILED", statusCode = 0))
    }
  }

  func search(query: in SearchQuery): Result[SearchResult, SearchError] {
    val queryJson = serializeQuery(query)
    match Search.Kernel.Net.search(clientHandle, queryJson) {
      case Ok(json)  -> Ok(parseSearchResult(json))
      case Err(err)  -> Err(SearchError(message = err, code = "SEARCH_FAILED", statusCode = 0))
    }
  }

  func suggest(index: in String, text: in String, field: in String, size: in Int): Result[SuggestResult, SearchError] {
    match Search.Kernel.Net.suggest(clientHandle, index, text, field, size) {
      case Ok(json)  -> Ok(parseSuggestResult(json))
      case Err(err)  -> Err(SearchError(message = err, code = "SUGGEST_FAILED", statusCode = 0))
    }
  }

  func delete(index: in String, id: in String): Result[Unit, SearchError] {
    match Search.Kernel.Net.delete(clientHandle, index, id) {
      case Ok(u)    -> Ok(u)
      case Err(err) -> Err(SearchError(message = err, code = "DELETE_FAILED", statusCode = 0))
    }
  }

  func deleteIndex(index: in String): Result[Unit, SearchError] {
    match Search.Kernel.Net.deleteIndex(clientHandle, index) {
      case Ok(u)    -> Ok(u)
      case Err(err) -> Err(SearchError(message = err, code = "DELETE_INDEX_FAILED", statusCode = 0))
    }
  }

  func exists(index: in String, id: in String): Result[Bool, SearchError] {
    match Search.Kernel.Net.exists(clientHandle, index, id) {
      case Ok(b)    -> Ok(b)
      case Err(err) -> Err(SearchError(message = err, code = "EXISTS_FAILED", statusCode = 0))
    }
  }

  func createIndex(index: in String, mappingJson: in String): Result[Unit, SearchError] {
    match Search.Kernel.Net.createIndex(clientHandle, index, mappingJson) {
      case Ok(u)    -> Ok(u)
      case Err(err) -> Err(SearchError(message = err, code = "CREATE_INDEX_FAILED", statusCode = 0))
    }
  }
}

// ─── Runtime config ───────────────────────────────────────────────────────────

/// Connection settings for the search backend.
config Connection {
  url:               String
  indexPrefix:       String                      = ""
  @sensitive
  apiKey:            String                      = ""
  @sensitive
  username:          String                      = ""
  @sensitive
  password:          String                      = ""
  connectTimeoutMs:  Int range 1000..=30000      = 5000
  requestTimeoutMs:  Int range 1000..=300000     = 30000
}

// ─── Factory ──────────────────────────────────────────────────────────────────

/// Connect to Elasticsearch using the Connection config block.
@stable(since="0.1")
@cfg(feature = "elasticsearch")
pub func connectElasticsearch(): Result[SearchClient, SearchError] {
  match Search.Kernel.Net.connectElasticsearch(
    Connection.url,
    Connection.apiKey,
    Connection.username,
    Connection.password,
    Connection.connectTimeoutMs,
    Connection.requestTimeoutMs)
  {
    case Ok(handle) -> Ok(NativeSearchClient(clientHandle = handle))
    case Err(err)   -> Err(SearchError(message = err, code = "CONNECT_FAILED", statusCode = 0))
  }
}

/// Connect to Meilisearch using the Connection config block.
@stable(since="0.1")
@cfg(feature = "meilisearch")
pub func connectMeilisearch(): Result[SearchClient, SearchError] {
  match Search.Kernel.Net.connectMeilisearch(
    Connection.url,
    Connection.apiKey,
    Connection.connectTimeoutMs)
  {
    case Ok(handle) -> Ok(NativeSearchClient(clientHandle = handle))
    case Err(err)   -> Err(SearchError(message = err, code = "CONNECT_FAILED", statusCode = 0))
  }
}

/// Dispatch to Elasticsearch or Meilisearch based on the `provider` string.
/// `provider` must be "elasticsearch" or "meilisearch".
@stable(since="0.1")
pub func connect(provider: in String): Result[SearchClient, SearchError]
  requires: provider.length > 0
{
  if provider == "elasticsearch" {
    match Search.Kernel.Net.connectElasticsearch(
      Connection.url,
      Connection.apiKey,
      Connection.username,
      Connection.password,
      Connection.connectTimeoutMs,
      Connection.requestTimeoutMs)
    {
      case Ok(handle) -> return Ok(NativeSearchClient(clientHandle = handle))
      case Err(err)   -> return Err(SearchError(message = err, code = "CONNECT_FAILED", statusCode = 0))
    }
  }
  if provider == "meilisearch" {
    match Search.Kernel.Net.connectMeilisearch(
      Connection.url,
      Connection.apiKey,
      Connection.connectTimeoutMs)
    {
      case Ok(handle) -> return Ok(NativeSearchClient(clientHandle = handle))
      case Err(err)   -> return Err(SearchError(message = err, code = "CONNECT_FAILED", statusCode = 0))
    }
  }
  return Err(SearchError(
    message    = "Unknown search provider: " + provider + ". Use \"elasticsearch\" or \"meilisearch\".",
    code       = "UNKNOWN_PROVIDER",
    statusCode = 0))
}

// ─── Convenience helpers ──────────────────────────────────────────────────────

/// Index a single document.
@stable(since="0.1")
pub func index(client: in SearchClient, doc: in SearchDocument): Result[IndexResult, SearchError]
  requires: doc.index.length > 0
  requires: doc.id.length > 0
{
  return client.index(doc)
}

/// Execute a search query.
@stable(since="0.1")
pub func search(client: in SearchClient, query: in SearchQuery): Result[SearchResult, SearchError]
  requires: query.index.length > 0
{
  return client.search(query)
}

/// Execute a simple keyword search with default pagination (from=0, size=10).
@stable(since="0.1")
pub func searchSimple(client: in SearchClient, index: in String, query: in String): Result[SearchResult, SearchError]
  requires: index.length > 0
{
  val q = SearchQuery(
    index           = index,
    query           = query,
    filters         = [],
    from            = 0,
    size            = 10,
    sort            = [],
    highlightFields = [])
  return client.search(q)
}

/// Delete a document by index and ID.
@stable(since="0.1")
pub func delete(client: in SearchClient, index: in String, id: in String): Result[Unit, SearchError]
  requires: index.length > 0
  requires: id.length > 0
{
  return client.delete(index, id)
}

/// Return autocomplete suggestions using a default size of 5.
@stable(since="0.1")
pub func suggest(client: in SearchClient, index: in String, text: in String, field: in String): Result[SuggestResult, SearchError]
  requires: index.length > 0
  requires: field.length > 0
{
  return client.suggest(index, text, field, 5)
}

/// Build a SearchQuery with default pagination and no filters, sort, or highlights.
@stable(since="0.1")
pub func makeQuery(index: in String, query: in String): SearchQuery
  requires: index.length > 0
{
  return SearchQuery(
    index           = index,
    query           = query,
    filters         = [],
    from            = 0,
    size            = 10,
    sort            = [],
    highlightFields = [])
}

/// Build an equality filter.
@stable(since="0.1")
pub func makeFilter(field: in String, value: in String): SearchFilter
  requires: field.length > 0
{
  return SearchFilter(field = field, value = value, operator = "eq")
}

/// Build a sort specification.
@stable(since="0.1")
pub func makeSort(field: in String, descending: in Bool): SortField
  requires: field.length > 0
{
  return SortField(field = field, descending = descending)
}

/// Build a SearchDocument from an index name, ID, and field map.
@stable(since="0.1")
pub func makeDoc(index: in String, id: in String, fields: in Map[String, String]): SearchDocument
  requires: index.length > 0
  requires: id.length > 0
{
  return SearchDocument(id = id, index = index, fields = fields)
}

// ─── Private serialization helpers ───────────────────────────────────────────

// Escape a string for JSON serialization (handles \, ", and common control chars).
func jsonEscapeStr(s: in String): String {
  var result = ""
  var i = 0
  while i < s.length {
    val ch = s.charAt(i).toString()
    if ch == "\\" {
      result = result + "\\\\"
    } else if ch == "\"" {
      result = result + "\\\""
    } else if ch == "\n" {
      result = result + "\\n"
    } else if ch == "\r" {
      result = result + "\\r"
    } else if ch == "\t" {
      result = result + "\\t"
    } else {
      result = result + ch
    }
    i = i + 1
  }
  return result
}

// Serialize a SearchDocument to a minimal JSON object for the kernel.
func serializeDoc(doc: in SearchDocument): String {
  var fieldsJson = "{"
  var first = true
  for (k, v) in doc.fields {
    if not first { fieldsJson = fieldsJson + "," }
    fieldsJson = fieldsJson + "\"" + jsonEscapeStr(k) + "\":\"" + jsonEscapeStr(v) + "\""
    first = false
  }
  fieldsJson = fieldsJson + "}"
  return "{\"id\":\"" + jsonEscapeStr(doc.id) + "\","
       + "\"index\":\"" + jsonEscapeStr(doc.index) + "\","
       + "\"fields\":" + fieldsJson + "}"
}

// Serialize a list of documents as a JSON array.
func serializeDocList(docs: in [SearchDocument]): String {
  var json = "["
  var first = true
  for doc in docs {
    if not first { json = json + "," }
    json = json + serializeDoc(doc)
    first = false
  }
  return json + "]"
}

// Serialize a SearchQuery to JSON for the kernel.
func serializeQuery(query: in SearchQuery): String {
  return "{\"index\":\"" + jsonEscapeStr(query.index) + "\","
       + "\"query\":\"" + jsonEscapeStr(query.query) + "\","
       + "\"from\":" + query.from.toString() + ","
       + "\"size\":" + query.size.toString() + "}"
}

// Parse an IndexResult from the JSON object returned by the kernel.
// Expected fields: id (String), version (Long), result (String).
func parseIndexResult(json: in String): IndexResult {
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  var id:      String = ""
  var version: Long   = 0
  var result:  String = "created"
  match Std.Json.tryGetProperty(root, "id") {
    case Some(v) -> id = Std.Json.getString(v)
    case None    -> ()
  }
  match Std.Json.tryGetProperty(root, "version") {
    case Some(v) ->
      match Std.Json.tryGetLong(v) {
        case Some(n) -> version = n
        case None    -> ()
      }
    case None -> ()
  }
  match Std.Json.tryGetProperty(root, "result") {
    case Some(v) -> result = Std.Json.getString(v)
    case None    -> ()
  }
  return IndexResult(id = id, version = version, result = result)
}

// Parse a JSON array of IndexResult objects returned by the kernel.
func parseIndexResultList(json: in String): [IndexResult] {
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  var results: [IndexResult] = []
  var en = Std.Json.enumerateArray(root)
  while Std.Json.arrayMoveNext(en) {
    val elem   = Std.Json.arrayCurrent(en)
    val raw    = Std.Json.getRawText(elem)
    results    = results + [parseIndexResult(raw)]
  }
  return results
}

// Parse a SearchResult from the JSON object returned by the kernel.
// Expected fields: total (Long), tookMs (Int), scrollId (String|null), hits (Array).
func parseSearchResult(json: in String): SearchResult {
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  var total:    Long          = 0
  var tookMs:   Int           = 0
  var scrollId: Option[String] = None
  var hits:     [SearchHit]   = []
  match Std.Json.tryGetProperty(root, "total") {
    case Some(v) ->
      match Std.Json.tryGetLong(v) {
        case Some(n) -> total = n
        case None    -> ()
      }
    case None -> ()
  }
  match Std.Json.tryGetProperty(root, "tookMs") {
    case Some(v) ->
      match Std.Json.tryGetInt(v) {
        case Some(n) -> tookMs = n
        case None    -> ()
      }
    case None -> ()
  }
  match Std.Json.tryGetProperty(root, "scrollId") {
    case Some(v) ->
      if Std.Json.valueKind(v) == 3 {   // 3 = string
        scrollId = Some(value = Std.Json.getString(v))
      }
    case None -> ()
  }
  match Std.Json.tryGetProperty(root, "hits") {
    case Some(arr) -> {
      var en = Std.Json.enumerateArray(arr)
      while Std.Json.arrayMoveNext(en) {
        val elem    = Std.Json.arrayCurrent(en)
        val hitJson = Std.Json.getRawText(elem)
        hits        = hits + [parseSearchHit(hitJson)]
      }
    }
    case None -> ()
  }
  return SearchResult(total = total, hits = hits, tookMs = tookMs, scrollId = scrollId)
}

// Parse a SuggestResult from the JSON object returned by the kernel.
// Expected fields: tookMs (Int), suggestions (Array of String).
func parseSuggestResult(json: in String): SuggestResult {
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  var tookMs:      Int      = 0
  var suggestions: [String] = []
  match Std.Json.tryGetProperty(root, "tookMs") {
    case Some(v) ->
      match Std.Json.tryGetInt(v) {
        case Some(n) -> tookMs = n
        case None    -> ()
      }
    case None -> ()
  }
  match Std.Json.tryGetProperty(root, "suggestions") {
    case Some(arr) -> {
      var en = Std.Json.enumerateArray(arr)
      while Std.Json.arrayMoveNext(en) {
        val elem = Std.Json.arrayCurrent(en)
        if Std.Json.valueKind(elem) == 3 {   // 3 = string
          suggestions = suggestions + [Std.Json.getString(elem)]
        }
      }
    }
    case None -> ()
  }
  return SuggestResult(suggestions = suggestions, tookMs = tookMs)
}

// Parse a single SearchHit from a raw JSON string.
// score is left as 0.0 — Std.Json exposes getDouble (Double) but SearchHit.score is Float.
func parseSearchHit(json: in String): SearchHit {
  val doc        = Std.Json.parseJson(json)
  val root       = Std.Json.rootElement(doc)
  var id:         String              = ""
  var index:      String              = ""
  var source:     Map[String, String] = Map.empty()
  var highlights: [Highlight]         = []
  match Std.Json.tryGetProperty(root, "id") {
    case Some(v) -> id = Std.Json.getString(v)
    case None    -> ()
  }
  match Std.Json.tryGetProperty(root, "index") {
    case Some(v) -> index = Std.Json.getString(v)
    case None    -> ()
  }
  match Std.Json.tryGetProperty(root, "source") {
    case Some(obj) -> {
      var en = Std.Json.enumerateObject(obj)
      while Std.Json.objectMoveNext(en) {
        val prop = Std.Json.objectCurrent(en)
        val k    = Std.Json.propertyName(prop)
        val v    = Std.Json.getString(Std.Json.propertyValue(prop))
        source   = source.set(k, v)
      }
    }
    case None -> ()
  }
  match Std.Json.tryGetProperty(root, "highlights") {
    case Some(arr) -> {
      var en = Std.Json.enumerateArray(arr)
      while Std.Json.arrayMoveNext(en) {
        val hElem    = Std.Json.arrayCurrent(en)
        val hJson    = Std.Json.getRawText(hElem)
        highlights   = highlights + [parseHighlight(hJson)]
      }
    }
    case None -> ()
  }
  return SearchHit(id = id, index = index, score = 0.0, highlights = highlights, source = source)
}

// Parse a Highlight from a raw JSON string.
// Expected fields: field (String), fragments (Array of String).
func parseHighlight(json: in String): Highlight {
  val doc        = Std.Json.parseJson(json)
  val root       = Std.Json.rootElement(doc)
  var field:     String   = ""
  var fragments: [String] = []
  match Std.Json.tryGetProperty(root, "field") {
    case Some(v) -> field = Std.Json.getString(v)
    case None    -> ()
  }
  match Std.Json.tryGetProperty(root, "fragments") {
    case Some(arr) -> {
      var en = Std.Json.enumerateArray(arr)
      while Std.Json.arrayMoveNext(en) {
        val fElem = Std.Json.arrayCurrent(en)
        if Std.Json.valueKind(fElem) == 3 {   // 3 = string
          fragments = fragments + [Std.Json.getString(fElem)]
        }
      }
    }
    case None -> ()
  }
  return Highlight(field = field, fragments = fragments)
}
