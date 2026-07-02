//! time_jvm_self_test.l — Std.Time on `--target jvm` regression test
//! (#3302, #3276, epic #2663 band J6).
//!
//! `_kernel_jvm/time_host.l` previously mixed a static-field extern
//! (`java.time.Duration.ZERO`, unresolvable — the JVM auto-FFI reads methods
//! only) with `@externTarget` references to a `lyric.stdlib.jvm.TimeHost`
//! shim class that never existed, so any program importing `Std.Time` failed
//! JVM codegen (blocking `lyric bench --target jvm`, #680, and aspect
//! `call.elapsed`).  The host is now pure Lyric over the JVM auto-FFI:
//! factory calls replace static fields (`ofMillis(0)` for ZERO), argument
//! order/unit divergences are bridged in Lyric bodies, and fractional
//! durations are preserved by rounding to whole nanoseconds.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`)
//! and runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.TimeSelfTest

import Std.Core
import Std.Testing
import Std.Time

test "duration constructors and totals round-trip" {
  val d = Time.millis(1500.0)
  assertTrue(Time.totalMillis(d) == 1500.0, "millis(1500).totalMillis")
  val s = Time.seconds(2.0)
  assertTrue(Time.totalSeconds(s) == 2.0, "seconds(2).totalSeconds")
}

test "zero duration compares below a positive duration" {
  val z = Time.zeroDuration()
  val d = Time.millis(1.0)
  assertTrue(Time.durationLess(z, d), "zero < 1ms")
  assertTrue(Time.durationGreater(d, z), "1ms > zero")
}

test "duration arithmetic" {
  val a = Time.millis(300.0)
  val b = Time.millis(200.0)
  assertTrue(Time.totalMillis(Time.addDurations(a, b)) == 500.0, "300ms + 200ms")
  assertTrue(Time.totalMillis(Time.subDurations(a, b)) == 100.0, "300ms - 200ms")
}

test "instant ordering and since" {
  val t0 = Time.now()
  val t1 = Time.plus(t0, Time.millis(250.0))
  assertTrue(Time.instantBefore(t0, t1), "t0 < t0+250ms")
  assertTrue(Time.instantAfter(t1, t0), "t0+250ms > t0")
  val el = Time.since(t1, t0)
  assertTrue(Time.totalMillis(el) == 250.0, "since(t1, t0) = 250ms")
}

test "epoch conversion and ISO-8601 formatting round-trip" {
  val t = Time.fromEpochMillis(1000000000000i64)
  assertEqual(Time.toIsoString(t), "2001-09-09T01:46:40Z", "epoch 1e12 ms ISO form")
  match Time.parseOptInstant("2021-01-01T00:00:00Z") {
    case Some(p) -> assertEqual(Time.toIsoString(p), "2021-01-01T00:00:00Z", "parse/format round-trip")
    case None -> assertTrue(false, "valid ISO instant must parse")
  }
}

test "malformed instant is rejected without throwing" {
  match Time.parseOptInstant("not-a-date") {
    case Some(_) -> assertTrue(false, "malformed input must not parse")
    case None -> assertTrue(true, "malformed input rejected")
  }
}

test "calendar arithmetic" {
  val epoch = Time.fromEpochMillis(0i64)
  assertEqual(Time.toIsoString(Time.addMonths(epoch, 1)), "1970-02-01T00:00:00Z", "epoch + 1 month")
  assertEqual(Time.toIsoString(Time.addYears(epoch, 2)), "1972-01-01T00:00:00Z", "epoch + 2 years")
  assertEqual(Time.toIsoString(Time.addDays(epoch, 1.5)), "1970-01-02T12:00:00Z", "epoch + 1.5 days")
}

test "monotonic clock advances across a sleep" {
  val m0 = Time.monotonicNanos()
  Time.sleepMillis(20)
  val m1 = Time.monotonicNanos()
  assertTrue(m1 > m0, "monotonicNanos must advance across sleepMillis(20)")
}

test "wall clock reports a modern epoch" {
  assertTrue(Time.nowEpochMillis() > 1600000000000i64, "nowEpochMillis after 2020-09-13")
}
