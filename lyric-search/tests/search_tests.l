//! tests/search_tests.l — tests for the pure-Lyric surface of the Search package.
//!
//! Covers SearchError, SearchDocument, SearchQuery, SearchResult type construction,
//! and pure factory helpers (makeDoc, makeQuery, makeFilter, makeSort).
//!
//! The "wired dispatch" section below proves connect/index/search/suggest/
//! delete actually reach `Search.Kernel.Net` / `Search.Kernel.Jvm` (issue
//! #5067) instead of the old hardcoded "not linked" / "no search backend
//! configured" stubs.  A live Elasticsearch or Meilisearch server is not
//! available in CI, so these tests cannot assert a successful round trip —
//! but see lyric-search/README.md "Platform parity" for why even a fake
//! server wouldn't help: `Search.Kernel.Net` / `Search.Kernel.Jvm` bind their
//! provider clients via `extern package` blocks that do not resolve to a
//! real FFI call on the current self-hosted compiler (confirmed on both
//! `--target dotnet` and `--target jvm`), so every call below deterministically
//! reaches `searchKernelFfiUnavailable`'s typed `Err` — this is what proves
//! the dispatch wiring is real: the message changed from the old, purely
//! static "elasticsearch not linked" placeholder to a message carrying a
//! live exception (`bug.message`) caught from an actual (failed) kernel
//! call.
@test_module
package Search.SearchTests

import Std.Core
import Std.Testing
import Std.Collections
import Std.String as Str
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

// ─── Wired dispatch (issue #5067) ─────────────────────────────────────────────
// `Search.connect` dispatches on the provider string before touching any
// kernel; an unknown provider must still resolve without reaching the kernel
// at all, regardless of which backend feature this build has active.
test "connect: unknown provider returns UNKNOWN_PROVIDER without touching the kernel" {
  match Search.connect("not-a-real-backend") {
    case Ok(_) -> assertTrue(false, "unknown provider must not connect")
    case Err(e) -> assertEqual(e.code, "UNKNOWN_PROVIDER", "unknown provider error code")
  }
}

// `test` blocks don't reliably survive `@cfg` erasure through test synthesis
// (observed to compile into an invalid MSIL program when gated directly),
// so the feature split lives on these two plain helper functions instead —
// `@cfg` on ordinary `func` items is the mechanism this file's own
// `searchConnectElasticsearch` / `searchConnectMeilisearch` wrappers already
// rely on, and it behaves correctly there.
@cfg(feature = "elasticsearch")
func probeConnect(): Result[SearchClient, SearchError] {
  Search.connectElasticsearch("http://127.0.0.1:1", "", "", "", 200, 200)
}

@cfg(feature = "meilisearch")
func probeConnect(): Result[SearchClient, SearchError] {
  Search.connectMeilisearch("http://127.0.0.1:1", "", 200)
}

test "connect*: dispatch reaches Search.Kernel.Net/Jvm, not the old hardcoded stub" {
  match probeConnect() {
    case Ok(_) -> assertTrue(false, "unexpected connect success against a closed port")
    case Err(e) -> {
      assertEqual(e.code, "CONNECT_FAILED", "connect failure surfaces as CONNECT_FAILED")
      // Before #5067's fix this message was the literal, static string
      // "elasticsearch not linked" / "meilisearch not linked" — it never
      // varied and never touched Search.Kernel.Net / Search.Kernel.Jvm.
      // Asserting it is gone proves the call now reaches the kernel (where
      // it currently fails on the separate, tracked extern-package gap —
      // see README.md "Platform parity").
      assertTrue(not Str.contains(e.message, "not linked"), "must not be the old hardcoded stub message")
      assertTrue(
        Str.contains(e.message, "search kernel FFI binding"),
        "must be the honest kernel-FFI-unavailable message, got: " + e.message
      )
    }
  }
}

// The generic client operations (search/suggest/delete/...) resolve through
// `NativeSearchClient` regardless of which backend feature is active, so
// these don't need an `@cfg` gate: `searchQuery` / `searchSuggest` /
// `searchDelete` are only split on `dotnet` vs `jvm`.  Constructing
// `NativeSearchClient` directly (rather than via `connect*`) exercises this
// surface without needing a live backend feature at all.
//
// `index`/`indexBatch` are not exercised here: `serializeDoc`'s `for k in
// doc.fields` loop (unchanged by this fix, pre-existing) hits a separate,
// already-latent self-hosted MSIL codegen bug where `Map` iteration
// (`for k in <Map[String,String]>`) throws
// `InvalidCastException: ... Dictionary ... to ... List` — confirmed with a
// minimal repro independent of Search.  That crash happens before any
// kernel dispatch is reached, so it isn't part of this issue; tracked
// separately (see README.md "Platform parity").
test "search: dispatch reaches the kernel for a directly-constructed client" {
  val client: SearchClient = NativeSearchClient(clientHandle = 1)
  val q = Search.makeQuery("products", "widget")
  match Search.search(client, q) {
    case Ok(_) -> assertTrue(false, "unexpected search success with no backend connected")
    case Err(e) -> assertTrue(Str.contains(e.message, "search kernel FFI binding"), "search must reach the kernel dispatch, got: " + e.message)
  }
}

test "suggest: dispatch reaches the kernel for a directly-constructed client" {
  val client: SearchClient = NativeSearchClient(clientHandle = 1)
  match Search.suggest(client, "products", "wid", "name") {
    case Ok(_) -> assertTrue(false, "unexpected suggest success with no backend connected")
    case Err(e) -> assertTrue(Str.contains(e.message, "search kernel FFI binding"), "suggest must reach the kernel dispatch, got: " + e.message)
  }
}

test "delete: dispatch reaches the kernel for a directly-constructed client" {
  val client: SearchClient = NativeSearchClient(clientHandle = 1)
  match Search.delete(client, "products", "p-1") {
    case Ok(_) -> assertTrue(false, "unexpected delete success with no backend connected")
    case Err(e) -> assertTrue(Str.contains(e.message, "search kernel FFI binding"), "delete must reach the kernel dispatch, got: " + e.message)
  }
}
