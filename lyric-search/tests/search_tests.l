// tests/search_tests.l — tests for the pure-Lyric surface of the Search package.
//
// Covers SearchError, SearchDocument, SearchQuery, SearchResult type construction,
// and pure factory helpers (makeDoc, makeQuery, makeFilter, makeSort).
// Backend connection and live search functions require an Elasticsearch or
// Meilisearch server and are not exercised here.

@test_module
package Search.SearchTests

import Std.Core
import Std.Testing
import Std.Collections
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
  val doc = Search.makeDoc("products", "p-1", Map.empty().set("name", "Widget"))
  assertEqual(doc.index, "products", "index field")
  assertEqual(doc.id,    "p-1",      "id field")
  match doc.fields.get("name") {
    case Some(v) -> assertEqual(v, "Widget", "name field value")
    case None    -> assertTrue(false, "name field must be present")
  }
}

test "makeDoc: empty fields map is valid" {
  val doc = Search.makeDoc("logs", "log-42", Map.empty())
  assertEqual(doc.index, "logs",   "index field")
  assertEqual(doc.id,    "log-42", "id field")
  assertTrue(doc.fields.count == 0, "empty fields map has count 0")
}

test "makeDoc: multiple fields are all accessible" {
  val fields = Map.empty()
    .set("title", "Hello")
    .set("body",  "World")
  val doc = Search.makeDoc("posts", "post-1", fields)
  match doc.fields.get("title") {
    case Some(v) -> assertEqual(v, "Hello", "title field")
    case None    -> assertTrue(false, "title must be present")
  }
  match doc.fields.get("body") {
    case Some(v) -> assertEqual(v, "World", "body field")
    case None    -> assertTrue(false, "body must be present")
  }
}

// ─── makeQuery ────────────────────────────────────────────────────────────────

test "makeQuery: index and query fields are set" {
  val q = Search.makeQuery("products", "Widget")
  assertEqual(q.index, "products", "index field")
  assertEqual(q.query, "Widget",   "query field")
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
  val r = SearchResult(total = 0L, hits = [], tookMs = 0)
  assertTrue(r.total == 0L, "total must be 0")
  assertTrue(r.hits.length == 0, "hits must be empty")
  assertEqualInt(r.tookMs, 0, "tookMs must be 0")
}

test "SearchResult: total carries document count" {
  val r = SearchResult(total = 42L, hits = [], tookMs = 5)
  assertTrue(r.total == 42L, "total carries document count")
}
