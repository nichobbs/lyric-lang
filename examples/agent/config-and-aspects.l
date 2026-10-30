//! Config blocks and aspects examples.
package Examples.ConfigAndAspects

import Std.Core
import Std.Collections

// ─── Config blocks ────────────────────────────────────────────────────────────

config Server {
  host: String = "0.0.0.0"
  port: Int range 1 ..= 65535 = 8080
}

// Env vars: LYRIC_CONFIG_EXAMPLES_CONFIGANDASPECTS_SERVER_HOST
//           LYRIC_CONFIG_EXAMPLES_CONFIGANDASPECTS_SERVER_PORT

config Db {
  url: String                   // required: no default, aborts at startup if absent
  poolSize: Int range 1 ..= 100 = 10
  @sensitive
  password: String = ""         // suppressed in logs and diagnostics
}

// Reading config (same package only):
func connectDb(): String {
  return "connecting to ${Db.url} with pool ${toString(Db.poolSize)}"
}

// ─── Aspects ──────────────────────────────────────────────────────────────────

// The advice below records each call in `trace`, so the order the aspects run
// in is visible in the output.
val trace: List[String] = newList()

// Basic logging aspect: matches all handle* functions.
aspect RequestLogging {
  matches: name like "handle*"

  around(call) -> ret {
    trace.add("log: enter ${call.shortName}")
    ret = proceed()
    trace.add("log: exit ${call.shortName}")
  }
}

// Auth aspect: runs outside RequestLogging.
aspect Auth {
  matches: name like "handle*"
  wraps: RequestLogging    // Auth is outermost: Auth -> RequestLogging -> function

  around(call) -> ret {
    trace.add("auth: check ${call.shortName}")
    ret = proceed()
  }
}

// Functions matched by both aspects:
pub func handleGetUser(id: in Int): String {
  return "user-${toString(id)}"
}

// Excluded from all aspects:
@no_aspect
pub func handleHealth(): String {
  return "ok"
}

// Excluded from RequestLogging only (Auth still applies):
@no_aspect("RequestLogging")
pub func handleMetrics(): String {
  return "metrics"
}

func drain(): String {
  var s = ""
  var i = 0
  while i < trace.count {
    if i > 0 {
      s = s + ", "
    }
    s = s + trace[i]
    i = i + 1
  }
  trace.clear()
  return s
}

func main(): Unit {
  println("server: ${Server.host}:${toString(Server.port)}")
  println(connectDb())

  println("getUser: ${handleGetUser(7)} [${drain()}]")
  println("health: ${handleHealth()} [${drain()}]")
  println("metrics: ${handleMetrics()} [${drain()}]")
}

// ─── FFI / extern ─────────────────────────────────────────────────────────────

// Use Std.File, Std.Http, Std.Time for common BCL surfaces.
// Only write extern declarations for BCL surface not covered by stdlib.

// import extern example, resolved against real BCL metadata at compile time:
// import extern System.{ Math }
// Math.Abs(-5)    // -> 5, statically bound, AOT-compatible
//
// Or use extern type to bind a specific type:
// extern type StringBuilder = "System.Text.StringBuilder"
// val sb = StringBuilder.new()  // supports constructor shorthand (.new)
