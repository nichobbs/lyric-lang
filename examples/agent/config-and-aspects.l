//! Config blocks and aspects examples.
package Examples.ConfigAndAspects
import Std.Core
import Std.Logging

// ─── Config blocks ────────────────────────────────────────────────────────────

config Server {
  host: String                = "0.0.0.0"
  port: Int range 1 ..= 65535 = 8080
}

// Env vars: LYRIC_CONFIG_EXAMPLES_CONFIGANDASPECTS_SERVER_HOST
//           LYRIC_CONFIG_EXAMPLES_CONFIGANDASPECTS_SERVER_PORT

config Db {
  url:      String              // required — no default, panics at startup if absent
  poolSize: Int range 1 ..= 100 = 10
  @sensitive
  password: String = ""         // suppressed in logs/diagnostics
}

// Reading config (same package only):
func connectDb(): Unit {
  val url  = Db.url          // String
  val pool = Db.poolSize     // Int
  println("connecting to ${url} with pool ${toString(pool)}")
}

// ─── Aspects ──────────────────────────────────────────────────────────────────

// Basic logging aspect — matches all handle* functions
aspect RequestLogging {
  matches: name like "handle*"

  around(args) -> ret {
    Std.Log.info("→ entering handler")
    proceed(args)
    Std.Log.info("← exiting handler")
  }
}

// Auth aspect — runs outside RequestLogging
aspect Auth {
  matches: name like "handle*"
  wraps: RequestLogging    // Auth is outermost: Auth → RequestLogging → function

  around(args) -> ret {
    if not AuthStore.isValid() {
      return Err(AppError.Unauthorized)
    }
    proceed(args)
  }
}

// Functions matched by both aspects:
pub func handleGetUser(id: in UserId): Result[User, AppError] {
  return userRepo.findById(id).toResult(AppError.NotFound)
}

// Excluded from all aspects:
@no_aspect
pub func handleHealth(): HealthStatus {
  return HealthStatus.ok()
}

// Excluded from RequestLogging only (Auth still applies):
@no_aspect("RequestLogging")
pub func handleMetrics(): MetricsPayload {
  return Metrics.snapshot()
}

// ─── FFI / extern ─────────────────────────────────────────────────────────────

// Use Std.File, Std.Http, Std.Time for common BCL surfaces.
// Only write extern declarations for BCL surface not covered by stdlib.

// import extern example — resolves against real BCL metadata at compile time:
// import extern System.{ Math }
// Math.Abs(-5)    // -> 5, statically bound, AOT-compatible
//
// Or use extern type to bind a specific type:
// extern type StringBuilder = "System.Text.StringBuilder"
// val sb = StringBuilder.new()  // supports constructor shorthand (.new)

// extern package example — hand-written with axiom:
// @axiom("System.Console.ReadLine returns null at EOF, non-null otherwise")
// extern package System.Console {
//   pub func readLine(): String?
//   pub func writeLine(s: in String): Unit
// }
//
// Wrapping pattern (convert exceptions to Result):
// pub func readLine(): Option[String] {
//   return try {
//     val line = SystemConsole.readLine()
//     Some(line)
//   } catch Bug as _ {
//     None
//   }
// }
