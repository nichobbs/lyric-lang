//! tests/search_live_tests.l - the Elasticsearch and Meilisearch operations
//! against a fake engine served by `Std.HttpServer`, so the request that goes
//! out and the response body that comes back are exercised for real (#8940).
//!
//! `search_tests.l` covers body construction and response parsing against
//! canned JSON, and the transport against a closed port. Nothing there reaches
//! a server that answers. Here every operation crosses `Std.Http` to a
//! listening `Std.HttpServer` on the loopback interface and reads the response
//! body back with `HttpResponse.bodyText` from outside `Std.Http`, the call the
//! README once recorded as crashing with `MissingMethodException`.
//!
//! The fake engine only answers when the request is the one the real engine
//! would accept (method, path, auth header and the fields of the body the
//! operation must send), so a malformed request shows up as an `Err`.
//!
//! The server runs on its own thread: a `Task.Run` worker on `--target dotnet`
//! (`spawn` is synchronous there), a `spawn` inside a `scope` on `--target
//! jvm`. The client scenario is a function that returns a transcript, so no
//! assertion runs while the server thread is waiting; the scenario ends by
//! asking the fake to stop, so a failed operation never leaves it blocked.
@test_module
package Search

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.Http
import Std.HttpServer

// ─── Fake server plumbing ────────────────────────────────────────────────────
val stopPath: String = "/__stop"

func headerValue(ctx: in HttpContext, name: in String): String {
  val wanted = Str.toLower(name)
  val entries = mapEntries(requestHeaders(ctx))
  var found = ""
  for e in entries {
    if Str.toLower(e.key) == wanted {
      found = e.value
    }
  }
  found
}

func has(haystack: in String, needle: in String): Bool {
  Str.contains(haystack, needle)
}

func serveUntilStopped(l: in HttpListener): Unit {
  var running = true
  while running {
    val ctx = nextContext(l)
    if requestPath(ctx) == stopPath {
      respondText(ctx, 200, "stopped")
      running = false
    } else {
      fakeEngine(ctx)
    }
  }
}

@cfg(target = "dotnet")
extern type Task = "System.Threading.Tasks.Task"

@cfg(target = "dotnet")
@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@cfg(target = "dotnet")
@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWait(t: in Task): Unit = ()

@cfg(target = "dotnet")
func withFakeEngine(port: in Int, scenario: in (String) -> String): String {
  val l = startListener("http://127.0.0.1:" + port.toString() + "/")
  val server = taskRun({ -> serveUntilStopped(l) })
  val transcript = scenario("http://127.0.0.1:" + port.toString())
  taskWait(server)
  stopListener(l)
  transcript
}

@cfg(target = "jvm")
func withFakeEngine(port: in Int, scenario: in (String) -> String): String {
  val l = startListener("http://127.0.0.1:" + port.toString() + "/")
  var transcript = ""
  scope {
    val server = spawn serveUntilStopped(l)
    transcript = scenario("http://127.0.0.1:" + port.toString())
    await server
  }
  stopListener(l)
  transcript
}

// Asks the fake to stop; the last thing every scenario does.
func stopFake(baseUrl: in String): Unit {
  val _ = await defaultClient().get(baseUrl + stopPath)
}

func okOrCode(r: in Result[Unit, SearchError]): String {
  match r {
    case Ok(_) -> "ok"
    case Err(e) -> e.code + ":" + e.statusCode.toString()
  }
}

func hitIds(r: in Result[SearchResult, SearchError]): String {
  match r {
    case Err(e) -> "err " + e.code + ":" + e.statusCode.toString() + " " + e.message
    case Ok(res) -> {
      var ids = res.total.toString() + "|"
      for h in res.hits {
        ids = ids + h.id + ","
      }
      ids
    }
  }
}

func existsText(r: in Result[Bool, SearchError]): String {
  match r {
    case Ok(true) -> "yes"
    case Ok(false) -> "no"
    case Err(e) -> "err " + e.code + ":" + e.statusCode.toString()
  }
}

func suggestText(r: in Result[SuggestResult, SearchError]): String {
  match r {
    case Err(e) -> "err " + e.code
    case Ok(s) -> {
      var seen = ""
      for t in s.suggestions {
        seen = seen + t + ","
      }
      seen
    }
  }
}

// An `async func` that awaits a call dispatched through `SearchClient`: the
// shape the README once recorded as throwing `InvalidProgramException`.
async func searchViaAsync(client: in SearchClient, q: in SearchQuery): Result[SearchResult, SearchError] {
  return await client.search(q)
}

func widgetDoc(): SearchDocument {
  val fields: Map[String, String] = newMap()
  fields.add("name", "Widget")
  makeDoc("products", "p-1", fields)
}

// ─── Elasticsearch ───────────────────────────────────────────────────────────
@cfg(feature = "elasticsearch")
func fakeEngine(ctx: in HttpContext): Unit {
  val m = requestMethod(ctx)
  val p = requestPath(ctx)
  val body = requestBody(ctx)
  if headerValue(ctx, "Authorization") != "ApiKey fake-key" {
    respondJson(ctx, 401, "{\"error\":\"missing credentials\"}")
  } else if m == "GET" and p == "/" {
    respondJson(ctx, 200, "{\"name\":\"fake\",\"version\":{\"number\":\"8.14.0\"}}")
  } else if m == "PUT" and p == "/products" {
    respondJson(ctx, 200, "{\"acknowledged\":true}")
  } else if m == "PUT" and p == "/products/_doc/p-1" {
    if has(body, "\"name\":\"Widget\"") {
      respondJson(ctx, 201, "{\"_id\":\"p-1\",\"_version\":4,\"result\":\"created\"}")
    } else {
      respondJson(ctx, 400, "{\"error\":\"unexpected document body\"}")
    }
  } else if m == "POST" and p == "/products/_search" {
    if has(body, "match_phrase_prefix") {
      respondJson(
        ctx,
        200,
        "{\"took\":2,\"hits\":{\"hits\":[{\"_id\":\"p-1\",\"_source\":{\"name\":\"Widget\"}}," +
          "{\"_id\":\"p-3\",\"_source\":{\"name\":\"Widget Pro\"}}]}}"
      )
    } else if has(body, "explode") {
      respondJson(ctx, 500, "{\"error\":{\"type\":\"search_phase_execution_exception\"}}")
    } else if has(body, "Widget") {
      respondJson(
        ctx,
        200,
        "{\"took\":7,\"hits\":{\"total\":{\"value\":2,\"relation\":\"eq\"},\"hits\":[" +
          "{\"_id\":\"p-1\",\"_index\":\"products\",\"_score\":1.5,\"_source\":{\"name\":\"Widget\"}," +
          "\"highlight\":{\"name\":[\"<em>Widget</em>\"]}}," +
          "{\"_id\":\"p-3\",\"_index\":\"products\",\"_score\":0.8,\"_source\":{\"name\":\"Widget Pro\"}}]}}"
      )
    } else {
      respondJson(ctx, 200, "{\"took\":1,\"hits\":{\"total\":{\"value\":0,\"relation\":\"eq\"},\"hits\":[]}}")
    }
  } else if m == "POST" and p == "/_bulk" {
    if has(body, "{\"index\":{\"_index\":\"products\",\"_id\":\"p-1\"}}") {
      respondJson(
        ctx,
        200,
        "{\"errors\":false,\"items\":[{\"index\":{\"_id\":\"p-1\",\"_version\":1,\"result\":\"created\",\"status\":201}}]}"
      )
    } else {
      respondJson(ctx, 400, "{\"error\":\"unexpected bulk body\"}")
    }
  } else if m == "GET" and p == "/products/_doc/p-1" {
    respondJson(ctx, 200, "{\"_id\":\"p-1\",\"found\":true}")
  } else if m == "GET" and p == "/products/_doc/missing" {
    respondJson(ctx, 404, "{\"found\":false}")
  } else if m == "DELETE" and p == "/products/_doc/p-1" {
    respondJson(ctx, 200, "{\"result\":\"deleted\"}")
  } else if m == "DELETE" and p == "/products/_doc/gone" {
    respondJson(ctx, 404, "{\"result\":\"not_found\"}")
  } else if m == "DELETE" and p == "/products" {
    respondJson(ctx, 200, "{\"acknowledged\":true}")
  } else {
    respondJson(ctx, 404, "{\"error\":\"no route for " + m + " " + p + "\"}")
  }
}

@cfg(feature = "elasticsearch")
func engineScenario(baseUrl: in String): String {
  val connected = await connectElasticsearch(baseUrl, "fake-key", "", "", 3000, 5000)
  var seen = ""
  match connected {
    case Err(e) -> {
      seen = "connect-err " + e.code + ":" + e.statusCode.toString() + " " + e.message
    }
    case Ok(client) -> {
      seen = seen + "create=" + okOrCode(await client.createIndex("products", "")) + ";"
      match index(client, widgetDoc()) {
        case Ok(r) -> {
          seen = seen + "index=" + r.id + "/" + r.version.toString() + "/" + r.status + ";"
        }
        case Err(e) -> {
          seen = seen + "index-err " + e.code + ":" + e.statusCode.toString() + ";"
        }
      }
      val batch: List[SearchDocument] = newList()
      batch.add(widgetDoc())
      match await client.indexBatch(batch.toArray()) {
        case Ok(rs) -> {
          seen = seen + "batch=" + rs.length.toString() + ";"
        }
        case Err(e) -> {
          seen = seen + "batch-err " + e.code + ":" + e.statusCode.toString() + ";"
        }
      }
      seen = seen + "search=" + hitIds(searchSimple(client, "products", "Widget")) + ";"
      seen = seen + "async=" + hitIds(await searchViaAsync(client, makeQuery("products", "Widget"))) + ";"
      seen = seen + "empty=" + hitIds(searchSimple(client, "products", "Gizmo")) + ";"
      seen = seen + "boom=" + hitIds(searchSimple(client, "products", "explode")) + ";"
      seen = seen + "suggest=" + suggestText(suggest(client, "products", "Wid", "name")) + ";"
      seen = seen + "exists=" + existsText(await client.exists("products", "p-1")) + ";"
      seen = seen + "missing=" + existsText(await client.exists("products", "missing")) + ";"
      seen = seen + "delete=" + okOrCode(delete(client, "products", "p-1")) + ";"
      seen = seen + "gone=" + okOrCode(delete(client, "products", "gone")) + ";"
      seen = seen + "dropIndex=" + okOrCode(await client.deleteIndex("products")) + ";"
    }
  }
  stopFake(baseUrl)
  seen
}

@cfg(feature = "elasticsearch")
test "elasticsearch: every operation round-trips through a listening server" {
  val transcript = withFakeEngine(19601, engineScenario)
  assertTrue(has(transcript, "create=ok;"), "createIndex: " + transcript)
  assertTrue(has(transcript, "index=p-1/4/created;"), "index reads _id, _version and result: " + transcript)
  assertTrue(has(transcript, "batch=1;"), "indexBatch parses the bulk response: " + transcript)
  assertTrue(has(transcript, "search=2|p-1,p-3,;"), "search reads total and hit ids from the body: " + transcript)
  assertTrue(has(transcript, "async=2|p-1,p-3,;"), "an async func awaiting the interface call: " + transcript)
  assertTrue(has(transcript, "empty=0|;"), "a query with no hits reads an empty result: " + transcript)
  assertTrue(has(transcript, "suggest=Widget,Widget Pro,;"), "suggest reads the suggestions: " + transcript)
  assertTrue(has(transcript, "exists=yes;"), "exists maps 200 to true: " + transcript)
  assertTrue(has(transcript, "missing=no;"), "exists maps 404 to false: " + transcript)
  assertTrue(has(transcript, "delete=ok;"), "delete: " + transcript)
  assertTrue(has(transcript, "dropIndex=ok;"), "deleteIndex: " + transcript)
}

@cfg(feature = "elasticsearch")
test "elasticsearch: a failing status from the engine reaches the caller as a typed SearchError" {
  val transcript = withFakeEngine(19602, engineScenario)
  assertTrue(has(transcript, "boom=err SEARCH_FAILED:500"), "a 500 keeps its operation code and status: " + transcript)
  assertTrue(has(transcript, "gone=DELETE_FAILED:404;"), "a 404 on delete keeps its code and status: " + transcript)
}

@cfg(feature = "elasticsearch")
func rejectedScenario(baseUrl: in String): String {
  val rejected = await connectElasticsearch(baseUrl, "wrong-key", "", "", 3000, 5000)
  var seen = ""
  match rejected {
    case Ok(_) -> {
      seen = "connected"
    }
    case Err(e) -> {
      seen = e.code + ":" + e.statusCode.toString()
    }
  }
  stopFake(baseUrl)
  seen
}

@cfg(feature = "elasticsearch")
test "elasticsearch: the api key is sent as an Authorization header and a rejection is reported" {
  assertEqual(withFakeEngine(19603, rejectedScenario), "CONNECT_FAILED:401", "401 from the health probe")
}

// ─── Meilisearch ─────────────────────────────────────────────────────────────
@cfg(feature = "meilisearch")
func fakeEngine(ctx: in HttpContext): Unit {
  val m = requestMethod(ctx)
  val p = requestPath(ctx)
  val body = requestBody(ctx)
  if headerValue(ctx, "Authorization") != "Bearer fake-key" {
    respondJson(ctx, 401, "{\"message\":\"missing credentials\",\"code\":\"missing_authorization_header\"}")
  } else if m == "GET" and p == "/health" {
    respondJson(ctx, 200, "{\"status\":\"available\"}")
  } else if m == "POST" and p == "/indexes" {
    respondJson(ctx, 202, "{\"taskUid\":1,\"status\":\"enqueued\",\"type\":\"indexCreation\"}")
  } else if m == "GET" and p == "/tasks/1" {
    respondJson(ctx, 200, "{\"uid\":1,\"status\":\"succeeded\"}")
  } else if m == "POST" and p == "/indexes/products/documents" {
    if has(body, "\"id\":\"p-1\"") and has(body, "\"name\":\"Widget\"") {
      respondJson(ctx, 202, "{\"taskUid\":5,\"status\":\"enqueued\",\"type\":\"documentAdditionOrUpdate\"}")
    } else {
      respondJson(ctx, 400, "{\"message\":\"unexpected document body\"}")
    }
  } else if m == "GET" and p == "/tasks/5" {
    respondJson(ctx, 200, "{\"uid\":5,\"status\":\"succeeded\"}")
  } else if m == "POST" and p == "/indexes/products/search" {
    if has(body, "\"limit\":5") {
      respondJson(
        ctx,
        200,
        "{\"hits\":[{\"id\":\"p-1\",\"name\":\"Widget\"},{\"id\":\"p-3\",\"name\":\"Widget Pro\"}],\"processingTimeMs\":2}"
      )
    } else if has(body, "explode") {
      respondJson(ctx, 500, "{\"message\":\"internal error\"}")
    } else if has(body, "Widget") {
      respondJson(
        ctx,
        200,
        "{\"hits\":[{\"id\":\"p-1\",\"name\":\"Widget\",\"_rankingScore\":0.9," +
          "\"_formatted\":{\"name\":\"<em>Widget</em>\"}},{\"id\":\"p-3\",\"name\":\"Widget Pro\",\"_rankingScore\":0.4}]," +
          "\"estimatedTotalHits\":2,\"processingTimeMs\":3}"
      )
    } else {
      respondJson(ctx, 200, "{\"hits\":[],\"estimatedTotalHits\":0,\"processingTimeMs\":1}")
    }
  } else if m == "GET" and p == "/indexes/products/documents/p-1" {
    respondJson(ctx, 200, "{\"id\":\"p-1\"}")
  } else if m == "GET" and p == "/indexes/products/documents/missing" {
    respondJson(ctx, 404, "{\"code\":\"document_not_found\"}")
  } else if m == "DELETE" and p == "/indexes/products/documents/p-1" {
    respondJson(ctx, 202, "{\"taskUid\":1,\"status\":\"enqueued\"}")
  } else if m == "DELETE" and p == "/indexes/products/documents/gone" {
    respondJson(ctx, 404, "{\"code\":\"document_not_found\"}")
  } else if m == "DELETE" and p == "/indexes/products" {
    respondJson(ctx, 202, "{\"taskUid\":1,\"status\":\"enqueued\"}")
  } else {
    respondJson(ctx, 404, "{\"message\":\"no route for " + m + " " + p + "\"}")
  }
}

@cfg(feature = "meilisearch")
func engineScenario(baseUrl: in String): String {
  val connected = await connectMeilisearch(baseUrl, "fake-key", 3000)
  var seen = ""
  match connected {
    case Err(e) -> {
      seen = "connect-err " + e.code + ":" + e.statusCode.toString() + " " + e.message
    }
    case Ok(client) -> {
      seen = seen + "create=" + okOrCode(await client.createIndex("products", "")) + ";"
      match index(client, widgetDoc()) {
        case Ok(r) -> {
          seen = seen + "index=" + r.id + "/" + r.status + ";"
        }
        case Err(e) -> {
          seen = seen + "index-err " + e.code + ":" + e.statusCode.toString() + ";"
        }
      }
      val batch: List[SearchDocument] = newList()
      batch.add(widgetDoc())
      match await client.indexBatch(batch.toArray()) {
        case Ok(rs) -> {
          seen = seen + "batch=" + rs.length.toString() + ";"
        }
        case Err(e) -> {
          seen = seen + "batch-err " + e.code + ":" + e.statusCode.toString() + ";"
        }
      }
      seen = seen + "search=" + hitIds(searchSimple(client, "products", "Widget")) + ";"
      seen = seen + "async=" + hitIds(await searchViaAsync(client, makeQuery("products", "Widget"))) + ";"
      seen = seen + "empty=" + hitIds(searchSimple(client, "products", "Gizmo")) + ";"
      seen = seen + "boom=" + hitIds(searchSimple(client, "products", "explode")) + ";"
      seen = seen + "suggest=" + suggestText(suggest(client, "products", "Wid", "name")) + ";"
      seen = seen + "exists=" + existsText(await client.exists("products", "p-1")) + ";"
      seen = seen + "missing=" + existsText(await client.exists("products", "missing")) + ";"
      seen = seen + "delete=" + okOrCode(delete(client, "products", "p-1")) + ";"
      seen = seen + "gone=" + okOrCode(delete(client, "products", "gone")) + ";"
      seen = seen + "dropIndex=" + okOrCode(await client.deleteIndex("products")) + ";"
    }
  }
  stopFake(baseUrl)
  seen
}

@cfg(feature = "meilisearch")
test "meilisearch: every operation round-trips through a listening server" {
  val transcript = withFakeEngine(19611, engineScenario)
  assertTrue(has(transcript, "create=ok;"), "createIndex waits for its task: " + transcript)
  assertTrue(has(transcript, "index=p-1/created;"), "index waits for the task to succeed: " + transcript)
  assertTrue(has(transcript, "search=2|p-1,p-3,;"), "search reads the estimated total and hit ids: " + transcript)
  assertTrue(has(transcript, "async=2|p-1,p-3,;"), "an async func awaiting the interface call: " + transcript)
  assertTrue(has(transcript, "empty=0|;"), "a query with no hits reads an empty result: " + transcript)
  assertTrue(has(transcript, "suggest=Widget,Widget Pro,;"), "suggest reads the suggestions: " + transcript)
  assertTrue(has(transcript, "exists=yes;"), "exists maps 200 to true: " + transcript)
  assertTrue(has(transcript, "missing=no;"), "exists maps 404 to false: " + transcript)
  assertTrue(has(transcript, "delete=ok;"), "delete: " + transcript)
  assertTrue(has(transcript, "dropIndex=ok;"), "deleteIndex: " + transcript)
}

@cfg(feature = "meilisearch")
test "meilisearch: a failing status from the engine reaches the caller as a typed SearchError" {
  val transcript = withFakeEngine(19612, engineScenario)
  assertTrue(has(transcript, "boom=err SEARCH_FAILED:500"), "a 500 keeps its operation code and status: " + transcript)
  assertTrue(has(transcript, "gone=DELETE_FAILED:404;"), "a 404 on delete keeps its code and status: " + transcript)
}

@cfg(feature = "meilisearch")
func rejectedScenario(baseUrl: in String): String {
  val rejected = await connectMeilisearch(baseUrl, "wrong-key", 3000)
  var seen = ""
  match rejected {
    case Ok(_) -> {
      seen = "connected"
    }
    case Err(e) -> {
      seen = e.code + ":" + e.statusCode.toString()
    }
  }
  stopFake(baseUrl)
  seen
}

@cfg(feature = "meilisearch")
test "meilisearch: the api key is sent as a bearer token and a rejection is reported" {
  assertEqual(withFakeEngine(19613, rejectedScenario), "CONNECT_FAILED:401", "401 from the health probe")
}
