# lyric-search

**Stability:** `experimental`

Search engine integration with pluggable backends (Elasticsearch, Meilisearch).

## Platform parity

**Update (issue #5408, resolved):** Elasticsearch and Meilisearch are now
implemented for real over plain HTTP + JSON — neither backend binds a
native SDK (`Elastic.Clients.Elasticsearch`, `com.meilisearch.sdk`, etc.).
`src/elasticsearch_backend.l` and `src/meilisearch_backend.l` implement
each engine's wire protocol directly on `Std.Http` / `Std.Json`. This
replaces the `extern package Elastic.Clients.Elasticsearch { ... }` /
`extern package MeilisearchDotnet { ... }` kernels that issue #5324 found
never resolved to a real FFI call on either backend (every call threw
`"unsupported method '<member>' on the receiver type..."` at runtime) —
those kernels, and the `Search.Kernel.Net` / `Search.Kernel.Jvm` packages
that housed them, are gone; there is no per-target kernel split any more
because there is no FFI boundary left to split on. `search.l`,
`elasticsearch_backend.l`, and `meilisearch_backend.l` are three files in
one `Search` package (see docs/19-multi-file-packages.md).

`connect(provider)` reads the `LYRIC_SEARCH_*` environment variables
documented below; the earlier version of this function hardcoded an empty
URL and could never have connected to anything, even once the underlying
kernel worked — that is fixed here too.

### Built on `Std.Http`, not `Std.Rest`

`Search` talks to the engine with `Std.Http` directly (an `HttpConfig` holding
a base URL and an optional auth header) rather than `Std.Rest.RestClient`.
`sendCatching` wraps `client.sendWithCancel` in a `try`/`catch Bug` and a
per-request deadline, so a transport failure or an elapsed deadline becomes a
typed `SearchError` (`ConnectionFailed`-derived, `statusCode = 0`), and a
non-2xx response keeps its HTTP status in `SearchError.statusCode`.

**Earlier versions of this README recorded three compiler defects** (a
cross-package `HttpClient.send` failing inside an `async func`, an `async
func` that awaits an interface call throwing `InvalidProgramException`, and
`HttpResponse.bodyText` throwing an uncatchable `MissingMethodException` from
outside `Std.Http`), and a phantom JVM `Std.Http` kernel (docs/59 H5). **None of
them reproduces on `main`** (#6358 for the first three, docs/59 wave 4 for
H5): `tests/search_live_tests.l` calls every operation across packages against
a fake engine served by `Std.HttpServer` and reads each response body back with
`HttpResponse.bodyText`, on `--target dotnet` and `--target jvm`, for both
backends (#8940). The convenience wrappers (`Search.index`/`search`/
`searchSimple`/`delete`/`suggest`) remain plain functions that await the
interface call; that is harmless, not a workaround.

### What the tests verify

* Every request-body-construction and response-parsing function
  (`esBuildSearchBody`, `esParseSearchResponse`, `esFilterClause`,
  `msBuildSearchBody`, `msParseSearchResponse`, `msFilterExpr`, ... - private to
  package `Search`; the tests are a `@test_module` of that package, D245)
  against canned JSON in each engine's documented response shape
  (`tests/search_tests.l`).
* The `HttpError` to `SearchError` mapping (`toSearchError`), including the real
  HTTP status in `SearchError.statusCode`, `pathEscape` (multi-byte UTF-8
  percent-encoding), and the refusal of empty or dot-segment index names and
  document ids.
* A closed TCP port (`http://127.0.0.1:1`) produces a real transport failure
  from `connect`/`search`/`suggest`/`delete`, and a silent in-process backend
  exercises the request deadline on the JVM.
* **A fake engine on a real listener** (`tests/search_live_tests.l`,
  `Std.HttpServer` on the loopback interface; a `Task.Run` worker on dotnet, a
  `spawn` in a `scope` on the JVM). The fake answers only when the request is
  the one the real engine would accept: method, path, the auth header
  (`Authorization: ApiKey ...` for Elasticsearch, `Bearer ...` for
  Meilisearch), and the fields the operation must put in the body. Covered per
  backend: `connect` (and a 401 rejection of the health probe), `createIndex`,
  `index`, `indexBatch`, `search` (hits, total, highlights, an empty result),
  `suggest`, `exists` (200 and 404), `delete` and `deleteIndex`, and a 500 and a
  404 reaching the caller as `SearchError` with the operation code and status.
  Meilisearch indexing also polls `GET /tasks/{uid}` until it succeeds.
* A gated integration test (`tests/search_tests.l`, "integration: live round
  trip...") performs connect, createIndex, index, search, delete and
  deleteIndex against a real cluster when `LYRIC_SEARCH_ELASTICSEARCH_URL` (or
  `LYRIC_SEARCH_MEILISEARCH_URL` under the `meilisearch` feature) is set, and
  otherwise asserts the clean-skip path:
  ```sh
  docker run -d -p 9200:9200 -e "discovery.type=single-node" \
    -e "xpack.security.enabled=false" docker.elastic.co/elasticsearch/elasticsearch:8.14.0
  LYRIC_SEARCH_ELASTICSEARCH_URL=http://localhost:9200 \
    ./bin/lyric test --manifest lyric-search/lyric.toml
  ```

**Not verified:** neither backend has been driven against a real Elasticsearch
or Meilisearch cluster in CI. The fake engine pins our requests and our parsing
of documented response shapes, not the engines' behaviour, which is why the
package is `experimental`.

The CI suites run `--target dotnet` with each backend feature and `--target
jvm` with the default (`elasticsearch`) feature; a JVM run with `--features
meilisearch` passes locally but is not in CI yet.

| Feature flag    | Backend                                          | Status                                                                 |
|-----------------|---------------------------------------------------|-------------------------------------------------------------------------|
| `elasticsearch` | Elasticsearch's HTTP + JSON REST API (`_doc`, `_search`, `_bulk`, ...) | Real on both targets, exercised against a fake engine; not yet against a real cluster |
| `meilisearch`   | Meilisearch's HTTP + JSON REST API (`documents`, `search`, `tasks`, ...) | Same status as `elasticsearch` |
| `--target dotnet` | either of the above | `Std.Http`'s .NET kernel |
| `--target jvm`    | either of the above | `Std.Http`'s JVM kernel (`java.net.http`) |

See `docs/57-stdlib-ecosystem-library-review.md` §3 and the `tests/` files above.

## Packages

`lyric-search` ships a single Lyric package, `Search`, spread across three
files (docs/19-multi-file-packages.md):

| File | Purpose |
|---|---|
| `src/search.l` | Public types (`SearchDocument`, `SearchQuery`, `SearchResult`, `SearchError`, ...), the `SearchClient` interface, `NativeSearchClient`, the `connect*` factory functions, and the `HttpConfig`-based HTTP transport layer shared by both backends (`pathEscape`, `toSearchError`, `sendRequest`, `readJsonBody`, ...) |
| `src/elasticsearch_backend.l` | Elasticsearch wire-protocol implementation (feature `elasticsearch`) |
| `src/meilisearch_backend.l` | Meilisearch wire-protocol implementation (feature `meilisearch`) |

`elasticsearch` and `meilisearch` are mutually exclusive per build — see
`lyric.toml`.

## Quick start

```lyric
import Search
import Std.Collections

// connectElasticsearch/connectMeilisearch are async — they perform a real
// HTTP health-check call.
match await Search.connectElasticsearch("http://localhost:9200", "", "", "", 5000, 30000) {
  case Err(e) -> println("connect error: " + e.message)
  case Ok(client) -> {
    // Index a document. (index/search/suggest/delete are plain functions
    // that internally await the interface call — see "Built on Std.Http,
    // not Std.Rest" above for why they aren't `async func` themselves.)
    val fields: Map[String, String] = newMap()
    fields.add("name", "Alice")
    fields.add("email", "alice@example.com")
    val doc = Search.makeDoc("users", "user-123", fields)
    Search.index(client, doc)

    // Search
    val query = Search.makeQuery("users", "Alice")
    match Search.search(client, query) {
      case Ok(results) -> println(results.hits.length.toString())
      case Err(error)  -> println("search error: " + error.message)
    }

    // Get suggestions
    match Search.suggest(client, "users", "ali", "name") {
      case Ok(suggestions) -> println(suggestions.suggestions.length.toString())
      case Err(error)      -> println("suggest error: " + error.message)
    }
  }
}
```

## SearchClient interface

`SearchClient` is a pluggable interface implemented by `NativeSearchClient`
(the only implementation today — obtained via `connectElasticsearch`,
`connectMeilisearch`, or the dispatching `connect`):

```lyric
pub interface SearchClient {
  async func index(doc: in SearchDocument): Result[IndexResult, SearchError]
  async func indexBatch(docs: in slice[SearchDocument]): Result[slice[IndexResult], SearchError]
  async func search(query: in SearchQuery): Result[SearchResult, SearchError]
  async func suggest(index: in String, text: in String, field: in String, size: in Int): Result[SuggestResult, SearchError]
  async func delete(index: in String, id: in String): Result[Unit, SearchError]
  async func deleteIndex(index: in String): Result[Unit, SearchError]
  async func exists(index: in String, id: in String): Result[Bool, SearchError]
  async func createIndex(index: in String, mappingJson: in String): Result[Unit, SearchError]
}
```

Call the `Search.*` convenience functions (`index`, `search`, `searchSimple`,
`delete`, `suggest`) or the interface methods directly. Awaiting a raw
`client.<method>(...)` from your own `async func` works too
(`searchViaAsync` in `tests/search_live_tests.l` pins it).

### Input validation

Index names, document ids, filters and pagination often come from clients,
so they are validated and rejected with an `Err` before any request is sent:

| Code | Rejected input |
|---|---|
| `INVALID_PATH_SEGMENT` | An index name or document id that is empty, `.` or `..`. URL normalisation would otherwise resolve `delete(index, "..")` to a request against the whole index, and an empty id would address every document. |
| `UNKNOWN_OPERATOR` | A `SearchFilter.operator` other than `eq`, `gt`, `gte`, `lt`, `lte` or `contains` (`isKnownFilterOperator`). A mistyped operator is not quietly treated as equality. |
| `INVALID_PAGINATION` | `from < 0`, `size < 0`, or `from + size > MAX_RESULT_WINDOW` (10000); or a `suggest` size outside 1..`MAX_RESULT_WINDOW`. |

## Backends

### Elasticsearch (`elasticsearch` feature, default)

`Search.connectElasticsearch(url, apiKey, username, password, connectTimeoutMs, requestTimeoutMs)`
connects directly, or use `Search.connect("elasticsearch")` to read connection
settings from the environment:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_SEARCH_ELASTICSEARCH_URL` | (required) | Elasticsearch base URL |
| `LYRIC_SEARCH_ELASTICSEARCH_USERNAME` | `""` | HTTP basic auth username |
| `LYRIC_SEARCH_ELASTICSEARCH_PASSWORD` | `""` | HTTP basic auth password |
| `LYRIC_SEARCH_ELASTICSEARCH_TIMEOUT_MS` | `30000` | Request timeout in milliseconds; a request still running after it is cancelled and reported as `ConnectionFailed` |
| `LYRIC_SEARCH_ELASTICSEARCH_CONNECT_TIMEOUT_MS` | `10000` | Timeout in milliseconds for the health probe `connect` sends first (`DEFAULT_CONNECT_TIMEOUT_MS`) |

`connect` uses API-key auth (`Authorization: ApiKey <key>`) when an API key
is supplied to `connectElasticsearch` directly; the env-var-driven `connect`
path only supports basic auth today (`LYRIC_SEARCH_ELASTICSEARCH_USERNAME`/
`PASSWORD`) — call `connectElasticsearch` directly for API-key auth.

Query mapping: `SearchQuery.query` becomes an Elasticsearch `query_string`
clause (or `match_all` when empty); filters map `eq` → `term`, `gt`/`gte`/
`lt`/`lte` → `range`, `contains` → `match`; `suggest` uses
`match_phrase_prefix`. See `elasticsearch_backend.l`'s header for the full
mapping table.

### Meilisearch (`meilisearch` feature)

`Search.connectMeilisearch(url, apiKey, connectTimeoutMs)` connects
directly (later requests use the 30000 ms default; `connectMeilisearchWithTimeouts` sets the per-request timeout), or use `Search.connect("meilisearch")`:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_SEARCH_MEILISEARCH_URL` | (required) | Meilisearch base URL |
| `LYRIC_SEARCH_MEILISEARCH_API_KEY` | `""` | API key (`Authorization: Bearer <key>`) |
| `LYRIC_SEARCH_MEILISEARCH_TIMEOUT_MS` | `30000` | Request timeout in milliseconds; a request still running after it is cancelled and reported as `ConnectionFailed` |
| `LYRIC_SEARCH_MEILISEARCH_CONNECT_TIMEOUT_MS` | `10000` | Timeout in milliseconds for the health probe `connect` sends first (`DEFAULT_CONNECT_TIMEOUT_MS`) |

Meilisearch's document/index mutation endpoints are asynchronous
(task-queue based); `Search.index`/`indexBatch`/`delete`/`deleteIndex`/
`createIndex` poll the enqueued task for up to ~1s and report the real
outcome (`IndexResult.status = "created"` on success, `"enqueued"` if the
task hadn't finished within that window). Filters map `eq` → `field =
'value'`, `gt`/`gte`/`lt`/`lte` → `field > 'value'` etc., `contains` →
`field CONTAINS 'value'`; `suggest` reuses Meilisearch's native
prefix-matching full-text search. See `meilisearch_backend.l`'s header for
the full mapping table.

To select Meilisearch instead of the default Elasticsearch build:

```sh
lyric build --manifest lyric-search/lyric.toml --no-default-features --features meilisearch
```

## API reference

```lyric
Search.connectElasticsearch(url, apiKey, username, password, connectTimeoutMs, requestTimeoutMs)
                                                    // async Result[SearchClient, SearchError]
Search.connectMeilisearch(url, apiKey, connectTimeoutMs)
                                                    // async Result[SearchClient, SearchError]
Search.connect(provider)                           // async Result[SearchClient, SearchError]; reads LYRIC_SEARCH_* env vars
Search.index(client, doc)                          // Result[IndexResult, SearchError]
Search.search(client, query)                       // Result[SearchResult, SearchError]
Search.searchSimple(client, index, query)          // Result[SearchResult, SearchError]
Search.suggest(client, index, text, field)         // Result[SuggestResult, SearchError]
Search.delete(client, index, id)                   // Result[Unit, SearchError]
Search.makeQuery(index, query)                     // SearchQuery
Search.makeFilter(field, value)                    // SearchFilter (operator = "eq")
Search.makeSort(field, descending)                 // SortField
Search.makeDoc(index, id, fields)                  // SearchDocument
```

## Decision log

See `docs/03-decision-log.md` D057 and `docs/10-bootstrap-progress.md`.
