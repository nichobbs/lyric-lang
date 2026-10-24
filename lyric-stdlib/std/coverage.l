//! std/coverage.l - the hit counters behind `lyric test --coverage` (#5294, D246).
//!
//! `lyric test --coverage` rewrites the code under test so that every
//! statement starts with `Std.Coverage.hit(<id>)`.  The counters live in this
//! module, which is pure Lyric: the same code counts on the .NET, JVM and
//! native targets.  The test binary calls `dumpFromEnv` as its last act; it
//! writes one `<id> <count>` line per statement that ran to the file named by
//! the `LYRIC_COVERAGE_OUT` environment variable, which `lyric test` reads
//! back and turns into an lcov / Cobertura report.  Without the variable
//! `dumpFromEnv` does nothing, so an instrumented binary run by hand is
//! harmless.
@io
package Std.Coverage

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Environment as Env
import Std.File as File

// The counters: a protected type, so statements counted from different
// threads (`spawn`, the parallel pool) never lose a hit or grow the table
// twice.
protected type Counters {
  var hits: List[Int] = newList()
  entry hit(id: in Int) {
    while hits.count <= id {
      hits.add(0)
    }
    hits[id] = hits[id] + 1
  }
  func dump(): String {
    var sb = ""
    var i = 0
    while i < hits.count {
      if hits[i] > 0 {
        sb = sb + toString(i) + " " + toString(hits[i]) + "\n"
      }
      i += 1
    }
    sb
  }
}

val counters: Counters = Counters()

/// Counts one run of the statement numbered `id`.  The compiler inserts the
/// call; it is public only because the instrumented package calls it.
@experimental
pub func hit(id: in Int): Unit {
  counters.hit(id)
}

/// The counts so far, one `<id> <count>` line per statement that ran.
@experimental
pub func report(): String {
  counters.dump()
}

/// Writes `report()` to the file named by `LYRIC_COVERAGE_OUT`, if the
/// variable is set and non-empty; a write error is reported on stderr and
/// leaves the run's exit status alone (the reader finds no file and says so).
@experimental
pub func dumpFromEnv(): Unit {
  val path = Env.getVarOrDefault("LYRIC_COVERAGE_OUT", "")
  if path.length > 0 {
    match File.writeText(path, counters.dump()) {
      case Ok(_) -> ()
      case Err(_) -> Console.error("coverage: cannot write " + path)
    }
  }
}
