/// End-to-end tests for `@stubbable` interface synthesis (D016 /
/// language reference §3.5).  The bootstrap-grade lowering generates
/// a sibling record `<I>Stub` with one `pub var <method>_value` field
/// per non-Unit method and an `impl I for <I>Stub` whose methods read
/// those fields directly.  See
/// `compiler/src/Lyric.Parser/Stubbable.fs` for the synthesis pass.
module Lyric.Emitter.Tests.StubbableTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "stub_single_method",
    """
package SB1

@stubbable
pub interface Clock {
  func now(): Int
}

func describe(c: in Clock): Unit {
  println(c.now())
}

func main(): Unit {
  val s = ClockStub(now_value = 42)
  describe(s)
}
""",
    "42"

    "stub_multi_method",
    """
package SB2

@stubbable
pub interface Repo {
  func count(): Int
  func exists(id: in Int): Bool
  func name(): String
}

func summarise(r: in Repo): Unit {
  println(r.count())
  println(r.exists(7))
  println(r.name())
}

func main(): Unit {
  val s = RepoStub(count_value = 99, exists_value = true, name_value = "Alice")
  summarise(s)
}
""",
    "99\nTrue\nAlice"

    "stub_unit_method_no_field",
    """
package SB3

@stubbable
pub interface Logger {
  func log(msg: in String): Unit
  func level(): Int
}

func emit(l: in Logger): Unit {
  l.log("hi")
  l.log("bye")
  println(l.level())
}

func main(): Unit {
  val s = LoggerStub(level_value = 7)
  emit(s)
}
""",
    "7"

    "stub_swappable_at_call_site",
    """
package SB4

@stubbable
pub interface PriceFeed {
  func priceOf(symbol: in String): Int
}

func portfolioValue(feed: in PriceFeed): Int {
  feed.priceOf("AAPL") + feed.priceOf("MSFT")
}

func main(): Unit {
  val s1 = PriceFeedStub(priceOf_value = 100)
  val s2 = PriceFeedStub(priceOf_value = 250)
  println(portfolioValue(s1))
  println(portfolioValue(s2))
}
""",
    "200\n500"

    "stub_only_when_annotation_present",
    """
package SB5

pub interface Plain {
  func ping(): Int
}

record PlainImpl { x: Int }

impl Plain for PlainImpl {
  func ping(): Int = self.x
}

func main(): Unit {
  println(PlainImpl(x = 13).ping())
}
""",
    "13"
]

let tests =
    testSequenced
    <| testList "@stubbable interface synthesis"
                (cases |> List.map mk)
