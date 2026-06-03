/// End-to-end tests for `Std.Testing.Mocking` (D-progress-073).
/// Provides `StubCounter` — a host-backed mutable cell that stubs
/// can hold and increment to record call counts.  Combined with
/// `@stubbable`, users can write thin wrapper records that proxy
/// to the auto-generated stub while incrementing a counter.
module Lyric.Emitter.Tests.MockingTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches"

let private cases : (string * string * string) list = [

    "stub_counter_basic_increment",
    """
package MK1
import Std.Core
import Std.Testing.Mocking
func main(): Unit {
  val c = makeStubCounter()
  println(toString(stubCounterGet(c)))
  stubCounterIncrement(c)
  stubCounterIncrement(c)
  stubCounterIncrement(c)
  println(toString(stubCounterGet(c)))
}
""",
    "0\n3"

    "stub_counter_reset",
    """
package MK2
import Std.Core
import Std.Testing.Mocking
func main(): Unit {
  val c = makeStubCounter()
  stubCounterIncrement(c)
  stubCounterIncrement(c)
  println(toString(stubCounterGet(c)))
  stubCounterReset(c)
  println(toString(stubCounterGet(c)))
  stubCounterIncrement(c)
  println(toString(stubCounterGet(c)))
}
""",
    "2\n0\n1"

    "stub_counter_with_stubbable_wrapper",
    // The user opts into call tracking by writing a thin
    // wrapper record that proxies to the auto-generated stub
    // and increments a counter on entry.  Demonstrates the
    // `@stubbable` + `StubCounter` composition pattern.
    """
package MK3
import Std.Core
import Std.Testing.Mocking

@stubbable
pub interface PriceFeed {
  func priceOf(symbol: in String): Int
}

record TrackedFeed { stub: PriceFeedStub, calls: StubCounter }
impl PriceFeed for TrackedFeed {
  func priceOf(symbol: in String): Int {
    stubCounterIncrement(self.calls)
    self.stub.priceOf(symbol)
  }
}

func portfolioValue(feed: in PriceFeed): Int {
  feed.priceOf("AAPL") + feed.priceOf("MSFT") + feed.priceOf("GOOG")
}

func main(): Unit {
  val calls = makeStubCounter()
  val tracked = TrackedFeed(
    stub  = PriceFeedStub(priceOf_value = 100),
    calls = calls)
  println(toString(portfolioValue(tracked)))
  println(toString(stubCounterGet(calls)))
}
""",
    "300\n3"
]

let tests =
    testSequenced
    <| testList "Std.Testing.Mocking (D-progress-073)"
        (cases |> List.map mk)
