//! Testing.Conformance.Search — conformance suite for `Search.SearchClient`.
//!
//! `run(factory)`: `factory` returns a client over a fresh, empty backend.
//! Documents must be visible to `search` once `index` has returned (an
//! Elasticsearch client refreshes on write; the in-memory fake in
//! `Testing.MockSearchClient` is synchronous).  An engine whose indexing is
//! eventually consistent must make `index` wait for visibility to conform.
//!
//! Cases run in sequence; a panic inside an async case ends the run (an
//! `await` cannot sit inside a `try`), unlike the synchronous suites.
//!
//! Text queries are matched as whole, case-insensitive words, which is what
//! every engine's default analyzer does for plain words; the suite uses only
//! plain lowercase words in its documents and queries.
@runtime_checked
@io
package Testing.Conformance.Search

import Std.Core
import Std.Collections
import Testing.Conformance
import Search as SearchLib

val IDX: String = "conformance-products"

/// Run the `SearchClient` contract against clients from `factory`.
@stable(since = "0.1")
pub async func run(factory: () -> SearchLib.SearchClient): Checks {
  val c = newChecks("SearchClient")
  beginCase(c, "createIndex, index and exists")
  await indexAndExists(c, factory())
  beginCase(c, "index returns the id and a status")
  await indexResult(c, factory())
  beginCase(c, "a text query matches whole words, case-insensitively")
  await textQuery(c, factory())
  beginCase(c, "an empty query matches every document")
  await matchAll(c, factory())
  beginCase(c, "an eq filter narrows the hits")
  await eqFilter(c, factory())
  beginCase(c, "from and size page through the hits and total counts them all")
  await paging(c, factory())
  beginCase(c, "sort orders the hits")
  await sorting(c, factory())
  beginCase(c, "a hit carries its source fields")
  await hitSource(c, factory())
  beginCase(c, "indexing an existing id replaces the document")
  await replaceDoc(c, factory())
  beginCase(c, "delete removes a document")
  await deleteDoc(c, factory())
  beginCase(c, "indexBatch indexes every document")
  await batch(c, factory())
  beginCase(c, "suggest returns prefix matches")
  await suggestions(c, factory())
  beginCase(c, "deleteIndex removes the index")
  await dropIndex(c, factory())
  beginCase(c, "invalid requests are refused with a typed error")
  await invalidRequests(c, factory())
  return c
}

func fields3(name: in String, color: in String, kind: in String): Map[String, String] {
  val m: Map[String, String] = newMap()
  m["name"] = name
  m["color"] = color
  m["kind"] = kind
  return m
}

func doc(id: in String, name: in String, color: in String, kind: in String): SearchLib.SearchDocument {
  return SearchLib.SearchDocument(id = id, index = IDX, fields = fields3(name, color, kind))
}

func query(
  text: in String,
  filters: in slice[SearchLib.SearchFilter],
  from: in Int,
  size: in Int,
  sort: in slice[SearchLib.SortField],
): SearchLib.SearchQuery {
  return SearchLib.SearchQuery(
    index = IDX,
    query = text,
    filters = filters,
    from = from,
    size = size,
    sort = sort,
    highlightFields = []
  )
}

async func put(c: in Checks, client: in SearchLib.SearchClient, d: in SearchLib.SearchDocument): Unit {
  match await client.index(d) {
    case Ok(_) -> expectTrue(c, true, "index " + d.id)
    case Err(e) -> failCase(c, "index " + d.id + " failed: " + e.code + " " + e.message)
  }
}

// Create the index and load the three fixture documents:
//   p1 "red widget" red tool, p2 "blue widget" blue tool, p3 "green gadget" green toy.
async func seeded(c: in Checks, client: in SearchLib.SearchClient): Unit {
  match await client.createIndex(IDX, "") {
    case Ok(_) -> expectTrue(c, true, "createIndex")
    case Err(e) -> failCase(c, "createIndex failed: " + e.code + " " + e.message)
  }
  await put(c, client, doc("p1", "red widget", "red", "tool"))
  await put(c, client, doc("p2", "blue widget", "blue", "tool"))
  await put(c, client, doc("p3", "green gadget", "green", "toy"))
}

async func searchOk(
  c: in Checks, client: in SearchLib.SearchClient, q: in SearchLib.SearchQuery
): SearchLib.SearchResult {
  match await client.search(q) {
    case Ok(r) -> return r
    case Err(e) -> {
      failCase(c, "search failed: " + e.code + " " + e.message)
      return SearchLib.SearchResult(total = 0i64, hits = [], tookMs = 0, scrollId = None)
    }
  }
}

func hitIds(r: in SearchLib.SearchResult): String {
  val ids: List[String] = newList()
  for h in r.hits {
    ids.add(h.id)
  }
  var joined = ""
  var i = 0
  while i < ids.count {
    joined = joined + (if i == 0 { "" } else { "," }) + ids[i]
    i = i + 1
  }
  return joined
}

func sortedHitIds(r: in SearchLib.SearchResult): String {
  val ids: List[String] = newList()
  for h in r.hits {
    ids.add(h.id)
  }
  // The fixtures use p1..p9, so a plain insertion sort on the id is enough.
  var i = 1
  while i < ids.count {
    var j = i
    while j > 0 and ids[j - 1] > ids[j] {
      val t = ids[j]
      ids[j] = ids[j - 1]
      ids[j - 1] = t
      j = j - 1
    }
    i = i + 1
  }
  var joined = ""
  var k = 0
  while k < ids.count {
    joined = joined + (if k == 0 { "" } else { "," }) + ids[k]
    k = k + 1
  }
  return joined
}

async func indexAndExists(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  match await client.exists(IDX, "p1") {
    case Ok(b) -> expectTrue(c, b, "an indexed document exists")
    case Err(e) -> failCase(c, "exists failed: " + e.code)
  }
  match await client.exists(IDX, "never-indexed") {
    case Ok(b) -> expectTrue(c, not b, "a never-indexed id does not exist")
    case Err(e) -> failCase(c, "exists failed: " + e.code)
  }
}

async func indexResult(c: in Checks, client: in SearchLib.SearchClient): Unit {
  match await client.createIndex(IDX, "") {
    case Ok(_) -> ()
    case Err(e) -> failCase(c, "createIndex failed: " + e.code)
  }
  match await client.index(doc("p1", "red widget", "red", "tool")) {
    case Ok(r) -> {
      expectEqual(c, r.id, "p1", "the indexed id")
      expectTrue(c, r.status.length > 0, "a status is reported")
    }
    case Err(e) -> failCase(c, "index failed: " + e.code)
  }
}

async func textQuery(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  val widgets = await searchOk(c, client, query("widget", [], 0, 10, []))
  expectEqualLong(c, widgets.total, 2i64, "total hits for \"widget\"")
  expectEqual(c, sortedHitIds(widgets), "p1,p2", "ids matching \"widget\"")
  val upper = await searchOk(c, client, query("WIDGET", [], 0, 10, []))
  expectEqual(c, sortedHitIds(upper), "p1,p2", "matching ignores case")
  val none = await searchOk(c, client, query("sprocket", [], 0, 10, []))
  expectEqualLong(c, none.total, 0i64, "total hits for an absent word")
  expectEqualInt(c, none.hits.length, 0, "no hits for an absent word")
}

async func matchAll(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  val all = await searchOk(c, client, query("", [], 0, 10, []))
  expectEqualLong(c, all.total, 3i64, "an empty query counts every document")
  expectEqual(c, sortedHitIds(all), "p1,p2,p3", "an empty query returns every document")
}

async func eqFilter(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  val tools = await searchOk(c, client, query("", [SearchLib.makeFilter("kind", "tool")], 0, 10, []))
  expectEqual(c, sortedHitIds(tools), "p1,p2", "kind = tool")
  val red = await searchOk(c, client, query("widget", [SearchLib.makeFilter("color", "red")], 0, 10, []))
  expectEqual(c, sortedHitIds(red), "p1", "text widget and color = red")
  val toys = await searchOk(c, client, query("widget", [SearchLib.makeFilter("kind", "toy")], 0, 10, []))
  expectEqualInt(c, toys.hits.length, 0, "no widget is a toy")
}

async func paging(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  val sortByName = [SearchLib.makeSort("name", false)]
  val first = await searchOk(c, client, query("", [], 0, 2, sortByName))
  expectEqualLong(c, first.total, 3i64, "total counts every match, not just the page")
  expectEqualInt(c, first.hits.length, 2, "the first page holds size hits")
  val second = await searchOk(c, client, query("", [], 2, 2, sortByName))
  expectEqualLong(c, second.total, 3i64, "total on the second page")
  expectEqualInt(c, second.hits.length, 1, "the last page holds the remainder")
  expectEqual(c, hitIds(first) + "," + hitIds(second), "p2,p3,p1", "the pages are consecutive in name order")
}

async func sorting(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  val asc = await searchOk(c, client, query("", [], 0, 10, [SearchLib.makeSort("name", false)]))
  expectEqual(c, hitIds(asc), "p2,p3,p1", "ascending by name (blue, green, red)")
  val desc = await searchOk(c, client, query("", [], 0, 10, [SearchLib.makeSort("name", true)]))
  expectEqual(c, hitIds(desc), "p1,p3,p2", "descending by name")
}

async func hitSource(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  val r = await searchOk(c, client, query("gadget", [], 0, 10, []))
  expectEqualInt(c, r.hits.length, 1, "one gadget")
  if r.hits.length == 1 {
    val h = r.hits[0]
    expectEqual(c, h.id, "p3", "the hit id")
    expectEqual(c, h.index, IDX, "the hit index")
    expectSome(c, mapGet(h.source, "color"), "green", "the color field")
    expectSome(c, mapGet(h.source, "kind"), "toy", "the kind field")
  }
}

async func replaceDoc(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  await put(c, client, doc("p1", "purple sprocket", "purple", "part"))
  val before = await searchOk(c, client, query("red", [], 0, 10, []))
  expectEqualInt(c, before.hits.length, 0, "the replaced text no longer matches")
  val fresh = await searchOk(c, client, query("sprocket", [], 0, 10, []))
  expectEqual(c, hitIds(fresh), "p1", "the replacement matches")
  val all = await searchOk(c, client, query("", [], 0, 10, []))
  expectEqualLong(c, all.total, 3i64, "replacing does not add a document")
}

async func deleteDoc(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  match await client.delete(IDX, "p2") {
    case Ok(_) -> expectTrue(c, true, "delete")
    case Err(e) -> failCase(c, "delete failed: " + e.code)
  }
  match await client.exists(IDX, "p2") {
    case Ok(b) -> expectTrue(c, not b, "the deleted document no longer exists")
    case Err(e) -> failCase(c, "exists failed: " + e.code)
  }
  val r = await searchOk(c, client, query("widget", [], 0, 10, []))
  expectEqual(c, hitIds(r), "p1", "the deleted document is not found")
}

async func batch(c: in Checks, client: in SearchLib.SearchClient): Unit {
  match await client.createIndex(IDX, "") {
    case Ok(_) -> ()
    case Err(e) -> failCase(c, "createIndex failed: " + e.code)
  }
  match await client.indexBatch([doc("b1", "alpha", "red", "tool"), doc("b2", "beta", "red", "tool")]) {
    case Ok(results) -> expectEqualInt(c, results.length, 2, "one result per document")
    case Err(e) -> failCase(c, "indexBatch failed: " + e.code)
  }
  val r = await searchOk(c, client, query("", [], 0, 10, []))
  expectEqualLong(c, r.total, 2i64, "both batch documents are searchable")
}

async func suggestions(c: in Checks, client: in SearchLib.SearchClient): Unit {
  match await client.createIndex(IDX, "") {
    case Ok(_) -> ()
    case Err(e) -> failCase(c, "createIndex failed: " + e.code)
  }
  await put(c, client, doc("s1", "widget", "red", "tool"))
  await put(c, client, doc("s2", "wiggle", "red", "tool"))
  await put(c, client, doc("s3", "gadget", "red", "tool"))
  match await client.suggest(IDX, "wi", "name", 5) {
    case Err(e) -> failCase(c, "suggest failed: " + e.code)
    case Ok(r) -> {
      var widget = false
      var wiggle = false
      var gadget = false
      for s in r.suggestions {
        if s == "widget" {
          widget = true
        }
        if s == "wiggle" {
          wiggle = true
        }
        if s == "gadget" {
          gadget = true
        }
      }
      expectTrue(c, widget, "\"widget\" is suggested for \"wi\"")
      expectTrue(c, wiggle, "\"wiggle\" is suggested for \"wi\"")
      expectTrue(c, not gadget, "\"gadget\" is not suggested for \"wi\"")
    }
  }
}

async func dropIndex(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  match await client.deleteIndex(IDX) {
    case Ok(_) -> expectTrue(c, true, "deleteIndex")
    case Err(e) -> failCase(c, "deleteIndex failed: " + e.code)
  }
  match await client.exists(IDX, "p1") {
    case Ok(b) -> expectTrue(c, not b, "a document of a deleted index does not exist")
    case Err(_) -> expectTrue(c, true, "a deleted index may answer an error instead")
  }
}

async func invalidRequests(c: in Checks, client: in SearchLib.SearchClient): Unit {
  await seeded(c, client)
  match await client.search(query("", [], -1, 10, [])) {
    case Err(e) -> expectEqual(c, e.code, "INVALID_PAGINATION", "a negative from")
    case Ok(_) -> failCase(c, "a negative from must be refused")
  }
  match await client.search(query("", [], 0, 10001, [])) {
    case Err(e) -> expectEqual(c, e.code, "INVALID_PAGINATION", "a size beyond the result window")
    case Ok(_) -> failCase(c, "a size beyond the result window must be refused")
  }
  val badOp = SearchLib.SearchFilter(field = "kind", value = "tool", operator = "like")
  match await client.search(query("", [badOp], 0, 10, [])) {
    case Err(e) -> expectEqual(c, e.code, "UNKNOWN_OPERATOR", "an unknown filter operator")
    case Ok(_) -> failCase(c, "an unknown filter operator must be refused")
  }
  match await client.exists(IDX, "..") {
    case Err(e) -> expectEqual(c, e.code, "INVALID_PATH_SEGMENT", "a dot-dot document id")
    case Ok(_) -> failCase(c, "a dot-dot document id must be refused")
  }
  match await client.suggest(IDX, "wi", "name", 0) {
    case Err(e) -> expectEqual(c, e.code, "INVALID_PAGINATION", "a zero suggestion size")
    case Ok(_) -> failCase(c, "a zero suggestion size must be refused")
  }
}
