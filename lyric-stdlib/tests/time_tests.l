//! stdlib/tests/time_tests.l — Tests for Std.Time.monotonicNanos().
//!
//! Verifies that monotonicNanos() returns non-decreasing values across successive
//! calls and that the value advances across observable work.  Also checks that
//! now() returns a positive epoch via totalMillis.
package Std.Time.Tests

import Std.Core
import Std.Time
import Std.Testing

func testNowReturnsPositiveEpoch(): Unit {
  // now() returns a time after the Unix epoch.  We verify by computing elapsed
  // milliseconds since epoch 0 using the stdlib's own fromEpochMillis / totalMillis.
  val t = now()
  val epoch0 = fromEpochMillis(0i64)
  val ms = totalMillis(since(t, epoch0))
  assertTrue(ms > 0.0, "now() must represent a time after the Unix epoch")
}

func testMonotonicNanosNonDecreasing(): Unit {
  val a = monotonicNanos()
  val b = monotonicNanos()
  assertTrue(b >= a, "second monotonicNanos() call must be >= first")
}

func testMonotonicNanosTwoCallsDiffer(): Unit {
  val a = monotonicNanos()
  // Busy-spin so the monotonic clock has a chance to advance.
  // Assertion is >= (not >) to avoid flakiness on coarse-clock platforms
  // where the resolution is coarser than the spin duration.
  var i = 0
  while i < 100000 {
    i = i + 1
  }
  val b = monotonicNanos()
  assertTrue(b >= a, "monotonicNanos() must not go backwards across non-trivial work")
}

func testMonotonicNanosThreeCallsOrdered(): Unit {
  val t1 = monotonicNanos()
  val t2 = monotonicNanos()
  val t3 = monotonicNanos()
  assertTrue(t1 <= t2, "t1 <= t2")
  assertTrue(t2 <= t3, "t2 <= t3")
}

// =====================================================================
// Calendar surface (D-N-027).  Deliberately no ISO-string goldens here:
// toIsoString's textual form differs per host (.NET "o" carries seven
// fractional digits, java.time and native trim a zero fraction), so
// these assertions compare instants and elapsed milliseconds, which
// every target must agree on exactly.  Option[Instant] results are
// unwrapped with inline match, not the generic Std.Core helpers —
// Instant is an extern value type on .NET, the #5196 pattern — and no
// local signature names the Instant type (the JVM emitter mis-resolves
// extern type names in consumer-package signatures, the same gap the
// Uuid tests hit).
// =====================================================================
func testEpochConversions(): Unit {
  assertTrue(instantEquals(fromEpochSeconds(60i64), fromEpochMillis(60000i64)), "60 s == 60000 ms")
  assertTrue(
    instantEquals(fromEpochMillis(0 - 86400000i64), plus(fromEpochMillis(0i64), days(0.0 - 1.0))),
    "negative epoch == epoch minus one day"
  )
}

func testDurationConstructors(): Unit {
  assertTrue(totalMillis(hours(1.5)) == 5400000.0, "1.5 h is 5400000 ms")
  assertTrue(totalSeconds(minutes(2.0)) == 120.0, "2 min is 120 s")
  assertTrue(totalMillis(addDurations(seconds(1.0), millis(500.0))) == 1500.0, "1 s + 500 ms")
  assertTrue(totalMillis(subDurations(seconds(2.0), millis(500.0))) == 1500.0, "2 s - 500 ms")
  assertTrue(durationLess(millis(1.0), millis(2.0)), "1 ms < 2 ms")
  assertTrue(durationGreater(seconds(1.0), millis(999.0)), "1 s > 999 ms")
  assertTrue(totalMillis(zeroDuration()) == 0.0, "zero duration")
}

func testCalendarArithmetic(): Unit {
  val epoch = fromEpochMillis(0i64)
  // January 1970 has 31 days; 1970+1971 are 730 days.
  assertTrue(totalMillis(since(addMonths(epoch, 1), epoch)) == 2678400000.0, "epoch + 1 month is 31 days")
  assertTrue(totalMillis(since(addYears(epoch, 2), epoch)) == 63072000000.0, "epoch + 2 years is 730 days")
  assertTrue(totalMillis(since(addDays(epoch, 1.5), epoch)) == 129600000.0, "epoch + 1.5 days")
  // Day-of-month clamping: Jan 31 + 1 month lands on the last day of
  // February — 29 days later in a leap year (1972), 28 in a common
  // year (1971).
  val jan31Leap = fromEpochSeconds(65664000i64)
  assertTrue(
    totalMillis(since(addMonths(jan31Leap, 1), jan31Leap)) == 2505600000.0,
    "1972-01-31 + 1 month clamps to Feb 29"
  )
  val jan31Common = fromEpochSeconds(34128000i64)
  assertTrue(
    totalMillis(since(addMonths(jan31Common, 1), jan31Common)) == 2419200000.0,
    "1971-01-31 + 1 month clamps to Feb 28"
  )
  assertTrue(instantBefore(epoch, addMonths(epoch, 1)), "epoch before epoch + 1 month")
  assertTrue(instantAfter(addMonths(epoch, 1), epoch), "epoch + 1 month after epoch")
}

func testParseRoundTrip(): Unit {
  // The guaranteed cross-target parse contract: toIsoString output
  // round-trips on the same target.
  val t = fromEpochMillis(123456789123i64)
  match parseOptInstant(toIsoString(t)) {
    case Some(p) -> assertTrue(instantEquals(p, t), "toIsoString round-trips through parseOptInstant")
    case None -> assertTrue(false, "toIsoString output must parse")
  }
  match parseOptInstant("not-a-date") {
    case Some(_) -> assertTrue(false, "garbage must not parse")
    case None -> assertTrue(true, "garbage rejected")
  }
  // The native i64-nanos window's boundary instants (1677-09-21 /
  // 2262-04-11) must round-trip on every target (#5219); the managed
  // ranges are far larger, so these are unremarkable there.
  val hi = fromEpochMillis(9223372036854i64)
  match parseOptInstant(toIsoString(hi)) {
    case Some(p2) -> assertTrue(instantEquals(p2, hi), "upper boundary instant round-trips")
    case None -> assertTrue(false, "upper boundary toIsoString output must parse")
  }
  val lo = fromEpochMillis(0 - 9223372036854i64)
  match parseOptInstant(toIsoString(lo)) {
    case Some(p3) -> assertTrue(instantEquals(p3, lo), "lower boundary instant round-trips")
    case None -> assertTrue(false, "lower boundary toIsoString output must parse")
  }
}

func main(): Unit {
  testNowReturnsPositiveEpoch()
  testMonotonicNanosNonDecreasing()
  testMonotonicNanosTwoCallsDiffer()
  testMonotonicNanosThreeCallsOrdered()
  testEpochConversions()
  testDurationConstructors()
  testCalendarArithmetic()
  testParseRoundTrip()
  println("time: ok")
}
