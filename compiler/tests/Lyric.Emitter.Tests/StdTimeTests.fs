/// End-to-end tests for the Std.Time expansion (C5 / D-progress-027).
///
/// New surface:
///   - `addMonths` / `addYears` / `addDays` — calendar arithmetic
///     with BCL day-of-month-preserving semantics.
///   - `fromEpochMillis` / `fromEpochSeconds` — Unix-epoch → Instant
///     via DateTimeOffset bridge.
///   - `hostFindTimeZone(id)` — IANA / Windows tz lookup.
module Lyric.Emitter.Tests.StdTimeTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    // 1714521600 seconds = 2024-05-01T00:00:00Z.
    "fromEpochSeconds_round_trip",
    """
package T1
import Std.Core
import Std.Time

func main(): Unit {
  val t = fromEpochSeconds(1714521600i64)
  println(toString(t))
}
""",
    "05/01/2024 00:00:00"

    "fromEpochMillis_round_trip",
    """
package T2
import Std.Core
import Std.Time

func main(): Unit {
  val t = fromEpochMillis(1714521600000i64)
  println(toString(t))
}
""",
    "05/01/2024 00:00:00"

    // BCL `AddMonths` preserves day-of-month where possible.
    "addMonths_basic",
    """
package T3
import Std.Core
import Std.Time

func main(): Unit {
  val t = fromEpochSeconds(1714521600i64)   // May 1 2024
  val u = addMonths(t, 2)                    // → July 1 2024
  println(toString(u))
}
""",
    "07/01/2024 00:00:00"

    "addYears_basic",
    """
package T4
import Std.Core
import Std.Time

func main(): Unit {
  val t = fromEpochSeconds(1714521600i64)
  val u = addYears(t, 5)
  println(toString(u))
}
""",
    "05/01/2029 00:00:00"

    "addDays_basic",
    """
package T5
import Std.Core
import Std.Time

func main(): Unit {
  val t = fromEpochSeconds(1714521600i64)
  val u = addDays(t, 30.0)
  println(toString(u))
}
""",
    "05/31/2024 00:00:00"

    // IANA / Windows-name lookup.  "UTC" is universally recognised.
    "hostFindTimeZone_utc",
    """
package T6
import Std.Core
import Std.Time

func main(): Unit {
  val tz = hostFindTimeZone("UTC")
  println(toString(tz))
}
""",
    "(UTC) Coordinated Universal Time"
]

let tests =
    testSequenced
    <| testList "Std.Time expansion (C5 / D-progress-027)"
                (cases |> List.map mk)
