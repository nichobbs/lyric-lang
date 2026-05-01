// examples/rest_service.l — minimal in-memory REST service.
//
// Endpoints:
//   GET  /              -> "Hello from Lyric!"
//   GET  /counter        -> { "count": <n> }
//   POST /counter/inc    -> { "count": <new-n> }   (increments)
//   GET  /time           -> { "now": "<ISO-ish>" }
//
// Run:
//   lyric run examples/rest_service.l
//   curl http://localhost:8080/counter
//   curl -X POST http://localhost:8080/counter/inc
//
// Single-threaded, synchronous accept loop — fine for a demo, not
// a production server.
package RestService

import Std.Core
import Std.Collections
import Std.HttpServer
import Std.Time
import Std.Json

func handle(ctx: in HttpContext, counter: in Map[String, Int]): Unit {
  val method = requestMethod(ctx)
  val path = requestPath(ctx)

  // Each branch responds + returns to keep the if/else chain
  // unambiguous about which writes the response.
  if method == "GET" {
    if path == "/" {
      respondText(ctx, 200, "Hello from Lyric!")
      return
    }
    if path == "/counter" {
      val n = counter["count"]
      respondJson(ctx, 200, "{\"count\": " + n + "}")
      return
    }
    if path == "/time" {
      val t = now()
      val body = "{\"now\": " + encodeString(toString(t)) + "}"
      respondJson(ctx, 200, body)
      return
    }
  }
  if method == "POST" {
    if path == "/counter/inc" {
      val n = counter["count"]
      val next = n + 1
      counter["count"] = next
      val body = "{\"count\": " + next + "}"
      respondJson(ctx, 200, body)
      return
    }
  }
  respondJson(ctx, 404, "{\"error\": \"not found\"}")
}

func main(): Unit {
  val counter: Map[String, Int] = newMap()
  counter.add("count", 0)

  val srv = startListener("http://localhost:8080/")
  println("Listening on http://localhost:8080/")
  while true {
    val ctx = nextContext(srv)
    handle(ctx, counter)
  }
}
