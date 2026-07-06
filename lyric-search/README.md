# lyric-search

Search engine integration with pluggable backends (Elasticsearch, Meilisearch).

## Platform parity

**Update (issue #5067, resolved as far as this layer goes):** `search.l`'s
public functions (`connectElasticsearch`, `connectMeilisearch`,
`index`/`search`/`suggest`/`delete`/`deleteIndex`/`exists`/`createIndex`
via `NativeSearchClient`) now genuinely import and dispatch into
`Search.Kernel.Net` (feature `dotnet`) or `Search.Kernel.Jvm` (feature
`jvm`), matching the target-selection pattern `lyric-storage` (#1444) and
`lyric-grpc` use. They are no longer permanently hardcoded to
`Err("... not linked")` / `Err("no search backend configured")`.

**But a deeper, separate defect blocks real connectivity on *both*
targets, discovered while wiring this up and empirically confirmed —
not part of #5067's original scope, and NOT fixed here:**
`Search.Kernel.Net` / `Search.Kernel.Jvm` bind the Elasticsearch and
Meilisearch clients via `extern package <Dotted.Path> { pub func ... }`
blocks. On the current self-hosted compiler, calling through this
mechanism **does not resolve to a real FFI call on either backend** — it
compiles cleanly but throws an unhandled runtime exception the first
time it is actually invoked:

* MSIL: `"unsupported method '<member>' on the receiver type at this call
  site (no matching user method, extern binding, or built-in intrinsic)"`
* JVM: an analogous JVM auto-FFI resolution failure (`"no matching
  instance or inherited method for '<type>.<member>(...)'"`)

This was verified three independent ways: (1) a minimal single-file
repro (`extern package System.Math { pub func Max(...) }` /
`extern package java.lang.Math { pub func max(...) }`) crashes identically
on both targets; (2) this package's own, unmodified `Search.Kernel.Net`
crashes the same way when actually called through the new wiring
(`./bin/lyric test --manifest lyric-search/lyric.toml`, calling
`Search.connectElasticsearch(...)`); (3) the failure is independent of
qualified vs. unqualified call syntax. Every wrapper in `search.l`'s
kernel-boundary section therefore wraps its kernel call in
`try { ... } catch Bug as bug { Err(...) }`, so callers get a typed,
honest `Err` (message: `"search kernel FFI binding for '<op>' did not
resolve on this target (extern package codegen is not yet implemented in
the self-hosted compiler...)"`) instead of an unhandled crash — but no
call to `connectElasticsearch` / `connectMeilisearch` (or any operation
on a connected client) can currently succeed, on either target.

This is a **compiler-level gap, not specific to lyric-search**: the same
`extern package`-only pattern (no matching `@externTarget`/`extern type`
binding backing it) is used by several other ecosystem library kernels —
at minimum `lyric-mail` (SES/SendGrid on JVM), `lyric-db`, `lyric-i18n`,
`lyric-lambda`, `lyric-jobs` (JVM), `lyric-ws` (JVM), `lyric-feature-flags`,
`lyric-web` (JVM), `lyric-grpc`, `lyric-otel`, `lyric-aws-secrets`,
`lyric-auth` (JVM), `lyric-aws-xray`, and `lyric-session` (JVM, `redis`
feature) — none of which have (to this investigation's knowledge) been
driven end-to-end either. `Std.Json`'s JVM kernel was already ported off
this exact pattern for the same reason (D-progress-555, see
`lyric-stdlib/std/_kernel_jvm/json_host.l`'s header) — that is the
precedent for the real fix: either implement `extern package` codegen in
both `lyric-compiler/msil/codegen.l` and `lyric-compiler/jvm/codegen/`, or
port each affected kernel to the working `extern type` + `@externTarget`
mechanism `lyric-mail`'s `.NET` kernel and `lyric-session`'s `.NET` kernel
already use. Tracked as **issue #5324**, a prerequisite for #5067's
*live-connectivity* goal, independent of the wiring fix landed here.

**Also discovered, also pre-existing and out of scope here:**
`serializeDoc`'s `for k in doc.fields` loop (a `Map[String, String]`
iteration, unchanged by this fix) hits a separate, already-latent
self-hosted MSIL codegen bug: `for k in <Map[String, String]>` throws
`InvalidCastException: ... Dictionary ... to ... List` regardless of
whether the map is empty, confirmed with a minimal repro independent of
`Search`. This means `Search.index` / `Search.indexBatch` cannot be
called successfully today even before reaching the kernel-FFI gap above.
`search`/`suggest`/`delete`/`deleteIndex`/`exists`/`createIndex` don't hit
this path (they serialize `slice[...]`, not `Map`) and are exercised in
`tests/search_tests.l`.

**Also observed (inconclusive, sandbox-specific):** in one investigation
sandbox, `lyric-search`'s declared `Lyric.Resilience` workspace dependency
(unused by any `Search` code — `grep -rn Resilience lyric-search/src
lyric-search/tests` returns nothing) failed to build for `--target jvm`
with an unrelated `MissingMethodException: System.Single
System.Convert.ToSingle(Double)` inside `Lyric.Resilience`'s own JVM
jitter/backoff codegen. This reproduced identically against an unmodified
checkout (`git stash`), so it predates and is unrelated to this fix; it
was blocking enough that a full `lyric test --manifest lyric-search/lyric.toml
--target jvm ...` run could not be completed in that sandbox. Worth
revisiting in an environment where `Lyric.Resilience`'s JVM build is known
green.

| Feature flag | Backend                                                       | Status                                                          |
|--------------|-----------------------------------------------------------------|------------------------------------------------------------------|
| `dotnet`     | `Elastic.Clients.Elasticsearch` + `Meilisearch` .NET clients (kernel) | Wired to the public API; kernel FFI call crashes, caught as `Err` |
| `jvm`        | `co.elastic.clients:elasticsearch-java` + Meilisearch Java (kernel)  | Wired to the public API; kernel FFI call crashes, caught as `Err` |

See `docs/57-stdlib-ecosystem-library-review.md` §3 (updated to reflect
this investigation's findings) and `tests/search_tests.l`'s "Wired
dispatch" section for the tests that pin the honest-`Err` behavior.

## Packages

| Package | Purpose |
|---|---|
| `Search` | Core types, `SearchClient` interface, and public API |
| `Search.Elasticsearch` | Elasticsearch-backed client (requires `elasticsearch` feature) |
| `Search.Meilisearch` | Meilisearch-backed client (requires `meilisearch` feature) |

## Quick start

```lyric
import Search

// Connect to Elasticsearch
val client = Search.connectElasticsearch("http://localhost:9200")

// Index a document
val doc = Search.SearchDocument(
  id: "user-123",
  index: "users",
  fields: ["name": "Alice", "email": "alice@example.com"]
)
Search.index(client, doc)

// Search
val query = Search.makeQuery(
  text: "Alice",
  filters: [Search.makeFilter("status", "active")],
  limit: 10
)

match Search.search(client, query) {
  case Ok(results)   -> printResults(results.hits)
  case Err(error)    -> println("search error: " + error)
}

// Get suggestions
match Search.suggest(client, "users", "ali") {
  case Ok(suggestions) -> println(suggestions)
  case Err(error)      -> println("suggest error: " + error)
}
```

## SearchClient interface

`SearchClient` is a pluggable interface for multiple backends:

```lyric
pub interface SearchClient {
  func index(doc: in SearchDocument): Result[IndexResult, String]
  func indexBatch(docs: in List[SearchDocument]): Result[Int, String]
  func search(query: in SearchQuery): Result[SearchResult, String]
  func suggest(index: in String, prefix: in String): Result[List[String], String]
  func delete(index: in String, id: in String): Result[Unit, String]
  func createIndex(name: in String, schema: in String): Result[Unit, String]
}
```

The v1 implementations are `ElasticsearchClient` (feature: `elasticsearch`) and
`MeilisearchClient` (feature: `meilisearch`).

## Backends

### Elasticsearch (`elasticsearch` feature)

`Search.connectElasticsearch(url)` connects to Elasticsearch. Configure via environment:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_SEARCH_ELASTICSEARCH_URL` | (required) | Elasticsearch base URL |
| `LYRIC_SEARCH_ELASTICSEARCH_USERNAME` | (optional) | Basic auth username |
| `LYRIC_SEARCH_ELASTICSEARCH_PASSWORD` | (optional) | Basic auth password |
| `LYRIC_SEARCH_ELASTICSEARCH_TIMEOUT_MS` | `30000` | Request timeout in milliseconds |

### Meilisearch (`meilisearch` feature)

`Search.connectMeilisearch(url, apiKey)` connects to Meilisearch. Configure via environment:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_SEARCH_MEILISEARCH_URL` | (required) | Meilisearch base URL |
| `LYRIC_SEARCH_MEILISEARCH_API_KEY` | (required) | API key for authentication |
| `LYRIC_SEARCH_MEILISEARCH_TIMEOUT_MS` | `30000` | Request timeout in milliseconds |

## API reference

```lyric
Search.connectElasticsearch(url)                   // SearchClient
Search.connectMeilisearch(url, apiKey)             // SearchClient
Search.index(client, doc)                          // Result[IndexResult, String]
Search.indexBatch(client, docs)                    // Result[Int, String]
Search.search(client, query)                       // Result[SearchResult, String]
Search.suggest(client, index, prefix)              // Result[List[String], String]
Search.delete(client, index, id)                   // Result[Unit, String]
Search.createIndex(client, name, schema)           // Result[Unit, String]
Search.makeQuery(text, filters, sorts, limit)      // SearchQuery
Search.makeFilter(field, value)                    // SearchFilter
Search.makeSort(field, ascending)                  // SortField
Search.makeDocument(id, index, fields)             // SearchDocument
```

## Configuration

Connection options are passed at connect time and via environment variables:

| Env var | Default | Meaning |
|---|---|---|
| `LYRIC_SEARCH_CONNECT_TIMEOUT_MS` | `10000` | Connection timeout in milliseconds |
| `LYRIC_SEARCH_REQUEST_TIMEOUT_MS` | `30000` | Request timeout in milliseconds |

## Decision log

See `docs/03-decision-log.md` D057 and `docs/10-bootstrap-progress.md`.
