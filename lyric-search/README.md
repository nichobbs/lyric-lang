# lyric-search

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

### Built on `Std.Http`, not `Std.Rest` — three compiler defects found and characterized

The natural choice for an HTTP client library was `Std.Rest.RestClient`
(base URL + auth + JSON verbs). It doesn't work: `RestClient.get`/`post`/
`put`/`patch`/`delete` throw `System.MissingMethodException` at runtime,
because they're implemented in terms of `Std.Http`'s free async functions
(`sendAsync`/`getAsync`/`postAsync`), which are the exact cross-package
free-async-function defect `lyric-lambda/src/dispatch.l`'s header
documents in detail (reproduced there with a 10-line, zero-Lambda-code
repro). So `Search` is built directly on `Std.Http` instead — but doing
that surfaced two more, previously-undocumented defects in the same
family, each independently reproduced with a small (~15-line) standalone
program carrying zero `Search` code:

1. **`HttpClient.send(req)` fails the same way `Std.Rest` does, but only
   from inside an `async func`.** It's an *interface* method (dynamic
   dispatch), not a free function, yet it throws the identical
   `"unsupported method 'send'..."` error when called from any package
   other than `Std.Http` — but *only* when the calling function is itself
   `async`. Calling it from a **plain (non-`async`) function**, wrapped in
   `try { await client.send(req) } catch Bug as bug { ... }`, reliably
   catches it as an ordinary `Bug`. (The reverse combination — `await`
   inside `try` inside an `async func` — is separately rejected at compile
   time by `V0012`, so this isn't optional: it's the only shape that
   builds *and* catches the failure.) **Worked around** — see
   `sendCatching` / `sendRequest` / `sendRequestRaw` in `search.l`.
2. **Any `async func` that itself `await`s an interface-dispatched call
   throws `System.InvalidProgramException` (bad IL), independent of
   `Std.Http`.** This one reproduces with `Search`'s own `SearchClient`
   interface — an `async func search(client, query) { return await
   client.search(query) }` crashes; the identical `client.search(query)`
   call from a plain function does not. **Worked around** for this
   package's own convenience wrappers (`Search.index`/`search`/
   `searchSimple`/`delete`/`suggest` are plain funcs, not `async func`,
   even though each is a one-line forward to the interface) — but a
   caller who writes their *own* `async func` around a raw
   `client.search(...)` call, bypassing these helpers, can still hit it.
3. **`HttpResponse.bodyText(response)` throws a raw
   `System.MissingMethodException` (not a Lyric `Bug`) under the same
   cross-package condition as defect 1 — and `try`/`catch Bug` does
   *not* catch it**, in an `async func` or otherwise. **Not worked
   around**: no catchable failure mode was found, and `HttpResponse`'s
   internals are opaque to this package, so there's no lower-level escape
   hatch either. Reading a response body from outside `Std.Http` is not
   currently possible. This means `readJsonBody` (used by every operation
   that needs the response payload — `index`, `search`, `suggest`, ...) is
   a **hard, uncaught crash** the moment a request actually reaches a live
   server that returns a body. Every path this package's own tests
   exercise fails earlier, at `send` (connection refused / DNS failure,
   caught by defect 1's workaround), so this crash is real but untested by
   CI — it is the one remaining live-connectivity blocker, and it is a
   `lyric-compiler`/`lyric-stdlib` defect, not a `lyric-search` one.

None of the three can be fixed from this directory. See `search.l`'s
`HttpConfig` doc comment for the full writeup with exact error text.

**Practical effect:** `connect`/`connectElasticsearch`/`connectMeilisearch`
(which only need a response *status*, not body, for their health probe)
and any operation whose target is unreachable (closed port, wrong host,
DNS failure) return a clean, typed `SearchError` — this is what the test
suite verifies. An operation that reaches a live, responding server and
needs to read its response body (which is all of them, on success) will
crash. Until compiler defect 3 is fixed, this library cannot be used
against a real, reachable Elasticsearch or Meilisearch instance.

**Elasticsearch and Meilisearch have not been driven against a live
cluster in this repository's CI** (no server is reachable in the sandbox
this was implemented in; see defect 3 above for why that would crash
today even if one were). What CI *does* verify:

* Every request-body-construction and response-parsing function
  (`esBuildSearchBody`, `esParseSearchResponse`, `esFilterClause`,
  `msBuildSearchBody`, `msParseSearchResponse`, `msFilterExpr`, ...) against
  canned, hand-written JSON matching each engine's real documented response
  shape — see `tests/search_tests.l`.
* The `HttpError` → `SearchError` mapping (`toSearchError`), including that
  a real HTTP status code (`BadStatus`) is threaded through to
  `SearchError.statusCode`, which used to be hardcoded to `0` for every
  failure.
* `pathEscape`, including multi-byte UTF-8 percent-encoding.
* A real HTTP call against a closed TCP port (`http://127.0.0.1:1`),
  proving `connect`/`search`/`suggest`/`delete` reach genuine transport
  code (defect 1's workaround) and surface a real `ConnectionFailed`-derived
  error, not a placeholder string.
* A gated integration test (`tests/search_tests.l`, "integration: live
  round trip...") that performs a full connect → createIndex → index →
  search → delete → deleteIndex round trip when
  `LYRIC_SEARCH_ELASTICSEARCH_URL` (or `LYRIC_SEARCH_MEILISEARCH_URL` under
  the `meilisearch` feature) is set, and otherwise asserts the clean-skip
  path. Point it at a real cluster locally — this will currently crash on
  defect 3 above once `index`/`search` reach a real response body, which is
  exactly what makes the blocker concrete rather than theoretical:
  ```sh
  docker run -d -p 9200:9200 -e "discovery.type=single-node" \
    -e "xpack.security.enabled=false" docker.elastic.co/elasticsearch/elasticsearch:8.14.0
  LYRIC_SEARCH_ELASTICSEARCH_URL=http://localhost:9200 \
    ./bin/lyric test --manifest lyric-search/lyric.toml
  ```

**Also discovered, also pre-existing and out of scope here:** the previous
kernel's `serializeDoc` hit a separate, already-latent self-hosted MSIL
codegen bug — `for k in <Map[String, String]>` throws
`InvalidCastException: ... Dictionary ... to ... List`. This rewrite's
`esFieldsToJsonObject` / `msDocToJsonObject` iterate
`Std.Collections.mapEntries(fields)` (a `List[MapEntry[K, V]]`) instead of
the map directly, which appears to route around that bug — `List`
iteration is not implicated in the report, and `esFieldsToJsonObject`'s own
unit test exercises it successfully. This has not been independently
re-confirmed against the original minimal repro.

### JVM: not currently functional (separate, lower-layer gap)

`Std.Http`'s JVM kernel (`lyric.stdlib.jvm.HttpClientHost`) does not exist
— `docs/59-compiler-stdlib-deep-review.md` finding **H5** documents five
`_kernel_jvm` files, including `_kernel/http_host.l`'s JVM twin, that bind
to phantom `lyric.stdlib.jvm.*` classes. This is a `lyric-stdlib` gap, not
a `lyric-search` one, and out of this repository slice's ownership to fix.
Once H5 is fixed in `lyric-stdlib`, `Search` should start working on
`--target jvm` with **no changes needed in this directory** — the same
"no change needed" property the old README claimed for #5324, now
actually true because the dependency is a real stdlib layer instead of a
`lyric-search`-local kernel (modulo the three defects above, which are
target-independent — they were all reproduced on `--target dotnet` and are
not specific to the JVM phantom-kernel gap).

| Feature flag    | Backend                                          | Status                                                                 |
|-----------------|---------------------------------------------------|-------------------------------------------------------------------------|
| `elasticsearch` | Elasticsearch's HTTP + JSON REST API (`_doc`, `_search`, `_bulk`, ...) | Request building, response parsing, and error mapping are implemented and tested. Connect / closed-port / unreachable-host failures return a clean `SearchError`. A request that reaches a live, responding server crashes reading the body (defect 3 above) |
| `meilisearch`   | Meilisearch's HTTP + JSON REST API (`documents`, `search`, `tasks`, ...) | Same status as `elasticsearch` |
| `--target dotnet` | either of the above | As described above; `Std.Http`'s .NET kernel is real |
| `--target jvm`    | either of the above | `Std.Http`'s JVM kernel is phantom (docs/59 H5) — every call fails, not a `lyric-search` gap |

See `docs/57-stdlib-ecosystem-library-review.md` §3 and
`tests/search_tests.l` for the tests referenced above.

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

Prefer the `Search.*` convenience functions (`index`, `search`,
`searchSimple`, `delete`, `suggest`) or calling these interface methods
directly from a non-`async` context. Wrapping a raw
`client.<method>(...)` call in your own `async func` can hit compiler
defect 2 above.

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
| `LYRIC_SEARCH_ELASTICSEARCH_TIMEOUT_MS` | `30000` | Request timeout in milliseconds |

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
directly, or use `Search.connect("meilisearch")`:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_SEARCH_MEILISEARCH_URL` | (required) | Meilisearch base URL |
| `LYRIC_SEARCH_MEILISEARCH_API_KEY` | `""` | API key (`Authorization: Bearer <key>`) |
| `LYRIC_SEARCH_MEILISEARCH_TIMEOUT_MS` | `30000` | Request timeout in milliseconds |

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
