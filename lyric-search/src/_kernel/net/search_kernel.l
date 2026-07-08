//! Search.Kernel.Net — Elasticsearch and Meilisearch extern boundaries.
//!
//! Bridges the Search package to the .NET search client libraries:
//!
//!   Elasticsearch (feature = "elasticsearch"):
//!     Elastic.Clients.Elasticsearch NuGet package.
//!     connectElasticsearch() — connect with API key or basic auth
//!     index / indexBatch / search / suggest / delete / deleteIndex / exists / createIndex
//!
//!   Meilisearch (feature = "meilisearch"):
//!     Meilisearch .NET client NuGet package.
//!     connectMeilisearch() — connect with API key
//!     index / indexBatch / search / suggest / delete / deleteIndex / exists / createIndex
//!
//! All document payloads are passed as JSON strings to avoid tying the
//! kernel interface to Lyric record types.  The Search package serialises
//! and deserialises at the boundary; the kernel forwards to the .NET SDK.
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package Search.Kernel.Net

import Std.Core

// ─── Elasticsearch ────────────────────────────────────────────────────────────
@axiom("Elastic.Clients.Elasticsearch .NET client")
@cfg(feature = "elasticsearch")
extern package Elastic.Clients.Elasticsearch {
  /// Open a connection to an Elasticsearch cluster.
  /// `apiKey` takes precedence over `username`/`password` when non-empty.
  /// Returns an opaque client handle.
  pub func connect(url: String, apiKey: String, username: String, password: String, connectTimeoutMs: Int, requestTimeoutMs: Int): Result[Int, String]
    requires: url.length > 0

  /// Index a document described by a JSON string.
  /// Returns an IndexResult JSON string.
  pub func index(clientHandle: Int, docJson: String): Result[String, String]
    requires: docJson.length > 0

  /// Bulk-index an array of documents described by a JSON array string.
  /// Returns a JSON array of IndexResult objects.
  pub func indexBatch(clientHandle: Int, docsJson: String): Result[String, String]
    requires: docsJson.length > 0

  /// Execute a search query described by a JSON string.
  /// Returns a SearchResult JSON string.
  pub func search(clientHandle: Int, queryJson: String): Result[String, String]
    requires: queryJson.length > 0

  /// Return autocomplete suggestions.
  /// Returns a SuggestResult JSON string.
  pub func suggest(clientHandle: Int, index: String, text: String, field: String, size: Int): Result[String, String]
    requires: index.length > 0
    requires: field.length > 0
    requires: size > 0

  /// Delete a single document by index and ID.
  pub func delete(clientHandle: Int, index: String, id: String): Result[Unit, String]
    requires: index.length > 0
    requires: id.length > 0

  /// Delete an entire index.
  pub func deleteIndex(clientHandle: Int, index: String): Result[Unit, String]
    requires: index.length > 0

  /// Return whether a document exists.
  pub func exists(clientHandle: Int, index: String, id: String): Result[Bool, String]
    requires: index.length > 0
    requires: id.length > 0

  /// Create an index with the given mapping JSON.
  pub func createIndex(clientHandle: Int, index: String, mappingJson: String): Result[Unit, String]
    requires: index.length > 0
  // ─── Meilisearch ──────────────────────────────────────────────────────────────
}

@axiom("Meilisearch .NET client")
@cfg(feature = "meilisearch")
extern package MeilisearchDotnet {
  /// Open a connection to a Meilisearch instance.
  /// `apiKey` may be empty for instances with no authentication.
  /// Returns an opaque client handle.
  pub func connect(url: String, apiKey: String, connectTimeoutMs: Int): Result[Int, String]
    requires: url.length > 0

  /// Index a document described by a JSON string.
  /// Returns an IndexResult JSON string.
  pub func index(clientHandle: Int, docJson: String): Result[String, String]
    requires: docJson.length > 0

  /// Bulk-index an array of documents described by a JSON array string.
  /// Returns a JSON array of IndexResult objects.
  pub func indexBatch(clientHandle: Int, docsJson: String): Result[String, String]
    requires: docsJson.length > 0

  /// Execute a search query described by a JSON string.
  /// Returns a SearchResult JSON string.
  pub func search(clientHandle: Int, queryJson: String): Result[String, String]
    requires: queryJson.length > 0

  /// Return autocomplete suggestions.
  /// Returns a SuggestResult JSON string.
  pub func suggest(clientHandle: Int, index: String, text: String, field: String, size: Int): Result[String, String]
    requires: index.length > 0
    requires: field.length > 0
    requires: size > 0

  /// Delete a single document by index and ID.
  pub func delete(clientHandle: Int, index: String, id: String): Result[Unit, String]
    requires: index.length > 0
    requires: id.length > 0

  /// Delete an entire index.
  pub func deleteIndex(clientHandle: Int, index: String): Result[Unit, String]
    requires: index.length > 0

  /// Return whether a document exists.
  pub func exists(clientHandle: Int, index: String, id: String): Result[Bool, String]
    requires: index.length > 0
    requires: id.length > 0

  /// Create an index with the given mapping JSON.
  pub func createIndex(clientHandle: Int, index: String, mappingJson: String): Result[Unit, String]
    requires: index.length > 0
  // ─── Re-export wrappers — Elasticsearch ───────────────────────────────────────
}

/// Connect to Elasticsearch.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub func connectElasticsearch(
  url: in String,
  apiKey: in String,
  username: in String,
  password: in String,
  connectTimeoutMs: in Int,
  requestTimeoutMs: in Int,
): Result[Int, String]
  requires: url.length > 0
{
  return Elastic.Clients.Elasticsearch.connect(url, apiKey, username, password, connectTimeoutMs, requestTimeoutMs)
}

// ─── Re-export wrappers — Meilisearch ─────────────────────────────────────────
/// Connect to Meilisearch.
@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub func connectMeilisearch(url: in String, apiKey: in String, connectTimeoutMs: in Int): Result[Int, String]
  requires: url.length > 0
{
  return MeilisearchDotnet.connect(url, apiKey, connectTimeoutMs)
}

// ─── Shared operation wrappers ────────────────────────────────────────────────
// These delegate to whichever backend is active at compile time.
// When both features are active the caller is responsible for using the
// correct handle (Elasticsearch handles are produced by connectElasticsearch,
// Meilisearch handles by connectMeilisearch).
/// Index a document.  `docJson` is a serialised SearchDocument.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub func index(clientHandle: in Int, docJson: in String): Result[String, String]
  requires: docJson.length > 0
{
  return Elastic.Clients.Elasticsearch.index(clientHandle, docJson)
}

@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub func index(clientHandle: in Int, docJson: in String): Result[String, String]
  requires: docJson.length > 0
{
  return MeilisearchDotnet.index(clientHandle, docJson)
}

/// Bulk-index documents.  `docsJson` is a serialised array of SearchDocument.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub func indexBatch(clientHandle: in Int, docsJson: in String): Result[String, String]
  requires: docsJson.length > 0
{
  return Elastic.Clients.Elasticsearch.indexBatch(clientHandle, docsJson)
}

@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub func indexBatch(clientHandle: in Int, docsJson: in String): Result[String, String]
  requires: docsJson.length > 0
{
  return MeilisearchDotnet.indexBatch(clientHandle, docsJson)
}

/// Execute a search query.  `queryJson` is a serialised SearchQuery.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub func search(clientHandle: in Int, queryJson: in String): Result[String, String]
  requires: queryJson.length > 0
{
  return Elastic.Clients.Elasticsearch.search(clientHandle, queryJson)
}

@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub func search(clientHandle: in Int, queryJson: in String): Result[String, String]
  requires: queryJson.length > 0
{
  return MeilisearchDotnet.search(clientHandle, queryJson)
}

/// Return autocomplete suggestions.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub func suggest(
  clientHandle: in Int, index: in String, text: in String, field: in String, size: in Int
): Result[String, String]
  requires: index.length > 0
  requires: field.length > 0
  requires: size > 0
{
  return Elastic.Clients.Elasticsearch.suggest(clientHandle, index, text, field, size)
}

@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub func suggest(
  clientHandle: in Int, index: in String, text: in String, field: in String, size: in Int
): Result[String, String]
  requires: index.length > 0
  requires: field.length > 0
  requires: size > 0
{
  return MeilisearchDotnet.suggest(clientHandle, index, text, field, size)
}

/// Delete a document by index and ID.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub func delete(clientHandle: in Int, index: in String, id: in String): Result[Unit, String]
  requires: index.length > 0
  requires: id.length > 0
{
  return Elastic.Clients.Elasticsearch.delete(clientHandle, index, id)
}

@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub func delete(clientHandle: in Int, index: in String, id: in String): Result[Unit, String]
  requires: index.length > 0
  requires: id.length > 0
{
  return MeilisearchDotnet.delete(clientHandle, index, id)
}

/// Delete an entire index.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub func deleteIndex(clientHandle: in Int, index: in String): Result[Unit, String]
  requires: index.length > 0
{
  return Elastic.Clients.Elasticsearch.deleteIndex(clientHandle, index)
}

@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub func deleteIndex(clientHandle: in Int, index: in String): Result[Unit, String]
  requires: index.length > 0
{
  return MeilisearchDotnet.deleteIndex(clientHandle, index)
}

/// Check whether a document exists.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub func exists(clientHandle: in Int, index: in String, id: in String): Result[Bool, String]
  requires: index.length > 0
  requires: id.length > 0
{
  return Elastic.Clients.Elasticsearch.exists(clientHandle, index, id)
}

@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub func exists(clientHandle: in Int, index: in String, id: in String): Result[Bool, String]
  requires: index.length > 0
  requires: id.length > 0
{
  return MeilisearchDotnet.exists(clientHandle, index, id)
}

/// Create an index with the given mapping JSON.
@stable(since = "0.1")
@cfg(feature = "elasticsearch")
pub func createIndex(clientHandle: in Int, index: in String, mappingJson: in String): Result[Unit, String]
  requires: index.length > 0
{
  return Elastic.Clients.Elasticsearch.createIndex(clientHandle, index, mappingJson)
}

@stable(since = "0.1")
@cfg(feature = "meilisearch")
pub func createIndex(clientHandle: in Int, index: in String, mappingJson: in String): Result[Unit, String]
  requires: index.length > 0
{
  return MeilisearchDotnet.createIndex(clientHandle, index, mappingJson)
}
