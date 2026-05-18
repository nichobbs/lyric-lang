// stdlib/tests/mocking_tests.l — Tests for Std.Testing.Mocking.
//
// Demonstrates idiomatic Lyric test isolation using @stubbable interfaces
// and StubCounter call-count verification. The pattern:
//
//   1. Annotate the dependency interface with @stubbable.
//   2. The compiler synthesises a <Name>Stub record with _value and
//      _counter fields for every non-Unit method.
//   3. Inject the stub (or a thin TrackedX wrapper) into the unit under
//      test instead of the real implementation.
//   4. After exercising the unit, read StubCounter to assert the
//      dependency was called the expected number of times.
package Std.Testing.Mocking.Tests

import Std.Core
import Std.Testing
import Std.Testing.Mocking

// ---------------------------------------------------------------------------
// Domain model — a simple invoice total calculator that depends on a
// price feed and a tax rate provider. Both are @stubbable so tests can
// exercise the calculator without hitting any real data source.
// ---------------------------------------------------------------------------

@stubbable
pub interface PriceFeed {
  func priceOf(symbol: in String): Int
}

@stubbable
pub interface TaxProvider {
  func rateForRegion(region: in String): Int
}

// Unit under test: compute the pre-tax subtotal + tax for a basket.
func invoiceTotal(
        feed: in PriceFeed,
        tax: in TaxProvider,
        symbols: in slice[String],
        region: in String): Int {
  var subtotal = 0
  for sym in symbols {
    subtotal += feed.priceOf(sym)
  }
  val taxRate = tax.rateForRegion(region)
  subtotal + (subtotal * taxRate / 100)
}

// ---------------------------------------------------------------------------
// Tracked wrappers that add per-call counter instrumentation.
// ---------------------------------------------------------------------------

record TrackedFeed {
  stub: PriceFeedStub
  calls: StubCounter
}
impl PriceFeed for TrackedFeed {
  func priceOf(symbol: in String): Int {
    stubCounterIncrement(self.calls)
    self.stub.priceOf(symbol)
  }
}

record TrackedTax {
  stub: TaxProviderStub
  calls: StubCounter
}
impl TaxProvider for TrackedTax {
  func rateForRegion(region: in String): Int {
    stubCounterIncrement(self.calls)
    self.stub.rateForRegion(region)
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func testBasicStubCounter(): Unit {
  val c = makeStubCounter()
  assertEqualInt(stubCounterGet(c), 0, "fresh counter is 0")

  stubCounterIncrement(c)
  stubCounterIncrement(c)
  assertEqualInt(stubCounterGet(c), 2, "counter after 2 increments")

  stubCounterReset(c)
  assertEqualInt(stubCounterGet(c), 0, "counter after reset")
}

func testStubValuesPassThrough(): Unit {
  val feed = PriceFeedStub(priceOf_value = 150)
  assertEqualInt(feed.priceOf("AAPL"), 150, "stub returns configured value")
  assertEqualInt(feed.priceOf("MSFT"), 150, "stub always returns same value")
}

func testCallCountTracking(): Unit {
  val feedCalls = makeStubCounter()
  val taxCalls  = makeStubCounter()

  val feed = TrackedFeed(
    stub  = PriceFeedStub(priceOf_value = 100),
    calls = feedCalls)
  val tax = TrackedTax(
    stub  = TaxProviderStub(rateForRegion_value = 10),
    calls = taxCalls)

  val total = invoiceTotal(feed, tax, ["AAPL", "MSFT", "GOOG"], "US")

  // 3 symbols → priceOf called 3 times; 1 region → rateForRegion called once
  assertEqualInt(stubCounterGet(feedCalls), 3, "priceOf called 3 times")
  assertEqualInt(stubCounterGet(taxCalls), 1, "rateForRegion called once")

  // 3 × 100 subtotal + 10% tax = 330
  assertEqualInt(total, 330, "invoice total with 10% tax")
}

func testCounterReuseAcrossScenarios(): Unit {
  val calls = makeStubCounter()
  val feed = TrackedFeed(
    stub  = PriceFeedStub(priceOf_value = 50),
    calls = calls)
  val tax = TaxProviderStub(rateForRegion_value = 0)

  // Scenario A: single item basket
  val _ = invoiceTotal(feed, tax, ["X"], "EU")
  assertEqualInt(stubCounterGet(calls), 1, "scenario A: 1 call")

  stubCounterReset(calls)

  // Scenario B: two-item basket after reset
  val _ = invoiceTotal(feed, tax, ["X", "Y"], "EU")
  assertEqualInt(stubCounterGet(calls), 2, "scenario B after reset: 2 calls")
}

func main(): Unit {
  testBasicStubCounter()
  testStubValuesPassThrough()
  testCallCountTracking()
  testCounterReuseAcrossScenarios()
  println("mocking: ok")
}
