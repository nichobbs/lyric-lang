# lyric-search

Search engine integration with pluggable backends (Elasticsearch, Meilisearch).

## Platform parity

| Feature flag | Backend                                                       | Status                |
|--------------|---------------------------------------------------------------|-----------------------|
| `dotnet`     | `Elastic.Clients.Elasticsearch` + `Meilisearch` .NET clients  | Available             |
| `jvm`        | `co.elastic.clients:elasticsearch-java` + Meilisearch Java    | Planned (Phase 6)     |

The JVM kernel (`Search.Kernel.Jvm`) declares the Elasticsearch +
Meilisearch JVM bindings; the `lyric.search.*` JVM helpers are
supplied by the Lyric JVM stdlib JAR (out-of-repo).  Until that JAR
ships, only the `dotnet` feature produces a runnable artifact.

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
