//! std/_kernel_jvm/time_host.l - JVM host boundary for java.time.*.
//!
//! Mirrors _kernel/time_host.l for the JVM target.  The java.time
//! package (JSR-310) maps cleanly onto Lyric's time model:
//!
//!   Instant        = java.time.Instant        (UTC point in time)
//!   Duration       = java.time.Duration       (elapsed time)
//!   DateTimeOffset = java.time.OffsetDateTime  (instant + UTC offset)
//!   TimeZone       = java.time.ZoneId          (IANA timezone name)
//!
//! Everything routes through the JVM auto-FFI (`extern type` resolved
//! from JDK metadata at compile time — no F#/Java shim class, no
//! @externTarget).  API divergences from the .NET host are bridged in
//! plain Lyric bodies:
//!
//!   - Duration constructors: java.time.Duration takes long, not
//!     Double; fractional inputs are preserved by converting to
//!     nanoseconds and rounding (Math.round), matching the .NET
//!     TimeSpan fractional-unit behaviour to 1 ns resolution.
//!   - hostSince: java.time.Duration.between(start, end) takes the
//!     earlier arg first, opposite of the .NET op_Subtraction ordering;
//!     the body swaps the arguments.
//!   - hostTotalMillis / hostTotalSeconds: derived from toNanos()
//!     (long) converted to Double in Lyric.  Durations beyond the
//!     toNanos() range (~292 years) raise the JDK ArithmeticException.
//!   - Calendar arithmetic (addMonths, addYears): Instant →
//!     OffsetDateTime(UTC) → plusMonths/plusYears → toInstant roundtrip.
//!   - Static-field constants (Duration.ZERO, ZoneOffset.UTC) are
//!     avoided — the auto-FFI resolves methods only — in favour of
//!     equivalent factory calls (ofMillis(0), ZoneOffset.of("Z")).
//!
//! Internal: only Std.Time should import this.
@axiom("java.time.* / java.lang.Math.round / java.lang.System.nanoTime / java.lang.Thread.sleep conform to their documented JVM / ISO 8601 contracts")
package Std.TimeHost

import Std.Core

// =====================================================================
// Wire-level type aliases.
// =====================================================================
extern type Instant = "java.time.Instant"

extern type Duration = "java.time.Duration"

extern type DateTimeOffset = "java.time.OffsetDateTime"

extern type TimeZone = "java.time.ZoneId"

extern type UtcOffset = "java.time.ZoneOffset"

extern type JMath = "java.lang.Math"

extern type JSystem = "java.lang.System"

extern type JThread = "java.lang.Thread"

// =====================================================================
// Construction.
// =====================================================================
/// Current UTC instant (java.time.Instant.now, nanosecond resolution).
pub func hostNow(): Instant {
  Instant.now()
}

/// The zero-length duration.  Duration.ZERO is a static field the
/// auto-FFI cannot resolve; ofMillis(0) is the equivalent factory.
pub func hostZeroDuration(): Duration {
  Duration.ofMillis(0)
}

/// Parse an ISO-8601 instant — the exception-free Option seam all
/// three kernel twins implement (D-N-027, replacing the former
/// Bool+out shape the native backend cannot express).  Instant.parse
/// throws DateTimeParseException on malformed input, absorbed into
/// the None arm.
pub func hostParseInstantOpt(s: in String): Option[Instant] {
  try {
    Some(value = Instant.parse(s))
  } catch Bug as _ {
    None
  }
}

// =====================================================================
// Duration constructors.  java.time factories take long; fractional
// Double inputs are preserved by rounding to whole nanoseconds.
// =====================================================================
pub func hostMillis(n: in Double): Duration {
  Duration.ofNanos(JMath.round(n * 1000000.0))
}

pub func hostSeconds(n: in Double): Duration {
  Duration.ofNanos(JMath.round(n * 1000000000.0))
}

pub func hostMinutes(n: in Double): Duration {
  Duration.ofNanos(JMath.round(n * 60000000000.0))
}

pub func hostHours(n: in Double): Duration {
  Duration.ofNanos(JMath.round(n * 3600000000000.0))
}

pub func hostDays(n: in Double): Duration {
  Duration.ofNanos(JMath.round(n * 86400000000000.0))
}

// =====================================================================
// Duration arithmetic on Instant.
// =====================================================================
/// Elapsed time from `earlier` to `later`.  Duration.between takes the
/// earlier argument first — the reverse of the .NET subtraction order —
/// so the body swaps them.
pub func hostSince(later: in Instant, earlier: in Instant): Duration {
  Duration.between(earlier, later)
}

pub func hostPlus(t: in Instant, d: in Duration): Instant {
  t.plus(d)
}

// =====================================================================
// Inspection.  toNanos() returns long; converted to Double in Lyric.
// =====================================================================
pub func hostTotalMillis(d: in Duration): Double {
  d.toNanos().toDouble() / 1000000.0
}

pub func hostTotalSeconds(d: in Duration): Double {
  d.toNanos().toDouble() / 1000000000.0
}

// =====================================================================
// Calendar arithmetic.  Months/years require the Instant →
// OffsetDateTime(UTC) → plus → toInstant roundtrip; fractional days
// are a plain Duration add.
// =====================================================================
pub func hostAddMonths(t: in Instant, n: in Int): Instant {
  t.atOffset(UtcOffset.of("Z")).plusMonths(n).toInstant()
}

pub func hostAddYears(t: in Instant, n: in Int): Instant {
  t.atOffset(UtcOffset.of("Z")).plusYears(n).toInstant()
}

pub func hostAddDays(t: in Instant, n: in Double): Instant {
  t.plus(hostDays(n))
}

// =====================================================================
// Epoch conversions.  Produce OffsetDateTime at UTC offset zero.
// =====================================================================
pub func hostDtoFromEpochMillis(n: in Long): DateTimeOffset {
  Instant.ofEpochMilli(n).atOffset(UtcOffset.of("Z"))
}

pub func hostDtoFromEpochSeconds(n: in Long): DateTimeOffset {
  Instant.ofEpochSecond(n).atOffset(UtcOffset.of("Z"))
}

pub func hostDtoUtcDateTime(d: in DateTimeOffset): Instant {
  d.toInstant()
}

/// Current UTC time as an OffsetDateTime (offset zero).
pub func hostDtoUtcNow(): DateTimeOffset {
  Instant.now().atOffset(UtcOffset.of("Z"))
}

/// Unix epoch-milliseconds of `d`.
pub func hostDtoToEpochMillis(d: in DateTimeOffset): Long {
  d.toInstant().toEpochMilli()
}

// =====================================================================
// IANA timezone lookup.
// =====================================================================
/// java.time.ZoneId.of(id) — throws ZoneRulesException for unknown ids.
pub func hostFindTimeZone(id: in String): TimeZone {
  TimeZone.of(id)
}

// =====================================================================
// Comparison.
// =====================================================================
pub func hostInstantBefore(a: in Instant, b: in Instant): Bool {
  a.isBefore(b)
}

pub func hostInstantAfter(a: in Instant, b: in Instant): Bool {
  a.isAfter(b)
}

pub func hostInstantEquals(a: in Instant, b: in Instant): Bool {
  a.equals(b)
}

/// a < b via compareTo (java.time.Duration has no operator surface).
pub func hostDurationLess(a: in Duration, b: in Duration): Bool {
  a.compareTo(b) < 0
}

/// a > b via compareTo.
pub func hostDurationGreater(a: in Duration, b: in Duration): Bool {
  a.compareTo(b) > 0
}

pub func hostAddDurations(a: in Duration, b: in Duration): Duration {
  a.plus(b)
}

pub func hostSubDurations(a: in Duration, b: in Duration): Duration {
  a.minus(b)
}

// =====================================================================
// ISO-8601 formatting.
// =====================================================================
/// Instant.toString() returns ISO-8601 (e.g. "2021-01-01T00:00:00Z"),
/// round-trippable via hostParseInstantOpt.
pub func hostInstantToString(value: in Instant): String {
  value.toString()
}

// ─── Monotonic clock ──────────────────────────────────────────────────────────
// System.nanoTime() returns nanoseconds directly; model it as a
// 1 GHz stopwatch so Std.Time.monotonicNanos uses the same formula on both platforms.
pub func hostStopwatchTimestamp(): Long {
  JSystem.nanoTime()
}

pub func hostStopwatchFrequency(): Long {
  1000000000i64
}

// ─── Synchronous sleep — block the calling thread for `ms` milliseconds ───────
// Thread.sleep takes a long; the Int argument widens via the auto-FFI
// numeric-widening match.  Backs Std.Time.sleepMillis.
pub func hostSleepMillis(ms: in Int): Unit {
  JThread.sleep(ms)
}

// =====================================================================
// Epoch/monotonic seams — the exception-free clock surface every
// kernel twin implements (issue #4752).
// =====================================================================
pub func hostEpochMillis(): Long {
  hostDtoToEpochMillis(hostDtoUtcNow())
}

pub func hostMonotonicNanos(): Long {
  JSystem.nanoTime()
}
